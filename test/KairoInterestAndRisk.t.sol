// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { TwoSlopeRateModel } from "../src/interest/TwoSlopeRateModel.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { DataTypes } from "../src/libraries/DataTypes.sol";
import { KairoRiskEngine } from "../src/risk/KairoRiskEngine.sol";
import { KairoTestBase } from "./helpers/KairoTestBase.sol";

contract KairoInterestAndRiskTest is KairoTestBase {
    function testAccrualAdvancesIndicesAndAllocatesReserves() public {
        _openPosition(100 ether, 100_000 * USDC_UNIT);
        DataTypes.MarketState memory beforeState = pool.getMarketState(address(usdc));

        vm.warp(block.timestamp + 30 days);
        uint256 resultingIndex = pool.accrueInterest(address(usdc));
        DataTypes.MarketState memory afterState = pool.getMarketState(address(usdc));

        uint256 accrued = afterState.totalBorrowAssets - beforeState.totalBorrowAssets;
        assertGt(resultingIndex, beforeState.borrowIndex);
        assertGt(afterState.supplyIndex, beforeState.supplyIndex);
        assertGt(accrued, 0);
        assertGt(afterState.totalSupplyAssets, beforeState.totalSupplyAssets);
        assertGt(afterState.totalReserves, beforeState.totalReserves);
        assertEq(afterState.lastAccrual, block.timestamp);
        assertApproxEqAbs(afterState.totalReserves, accrued / 10, 2);
    }

    function testAccruedReservesCanBeClaimedByTreasuryRole() public {
        _openPosition(100 ether, 100_000 * USDC_UNIT);
        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest(address(usdc));

        uint256 reserves = pool.getMarketState(address(usdc)).totalReserves;
        uint256 amount = reserves / 2;
        pool.claimReserves(address(usdc), amount, treasury);

        assertEq(usdc.balanceOf(treasury), amount);
        assertEq(pool.getMarketState(address(usdc)).totalReserves, reserves - amount);
    }

    function testSmallBorrowersCanClosePositionsAfterIndexRounding() public {
        TwoSlopeRateModel fixedRateModel =
            new TwoSlopeRateModel(OPTIMAL_UTILIZATION, RAY / 365 days + 1e12, 0, 0);
        pool.setReserveFactor(address(usdc), 0);
        pool.setMarketSources(address(usdc), address(usdcOracle), address(fixedRateModel), 2 days);

        _supplyCollateral(borrower, 1 ether);
        _supplyCollateral(recipient, 1 ether);
        _borrow(borrower, 1);
        _borrow(recipient, 1);

        vm.warp(block.timestamp + 365 days / 2 + 1);
        usdc.mint(borrower, 2);
        usdc.mint(recipient, 2);
        _approvePool(borrower, usdc, type(uint256).max);
        _approvePool(recipient, usdc, type(uint256).max);

        vm.prank(borrower);
        pool.repay(address(usdc), type(uint256).max, borrower);
        vm.prank(recipient);
        pool.repay(address(usdc), type(uint256).max, recipient);

        DataTypes.MarketState memory state = pool.getMarketState(address(usdc));
        assertEq(pool.borrowBalance(address(usdc), borrower), 0);
        assertEq(pool.borrowBalance(address(usdc), recipient), 0);
        assertEq(state.totalBorrowAssets, 0);
        assertEq(state.totalReserves, 1);
    }

    function testPriceChangeUpdatesHealthFactorAndShortfall() public {
        _openPosition(10 ether, 10_000 * USDC_UNIT);

        DataTypes.AccountLiquidity memory beforeMove = riskEngine.getAccountLiquidity(borrower);
        assertGt(beforeMove.healthFactor, WAD);
        assertEq(beforeMove.shortfall, 0);
        assertFalse(riskEngine.isLiquidatable(borrower));

        wethPrimary.setPrice(1000 * PRICE_UNIT);
        DataTypes.AccountLiquidity memory afterMove = riskEngine.getAccountLiquidity(borrower);

        assertLt(afterMove.healthFactor, WAD);
        assertGt(afterMove.shortfall, 0);
        assertLt(afterMove.collateralValue, beforeMove.collateralValue);
        assertTrue(riskEngine.isLiquidatable(borrower));
    }

    function testLiquidationAppliesCloseFactorAndTransfersCollateralShares() public {
        _openPosition(10 ether, 10_000 * USDC_UNIT);
        wethPrimary.setPrice(1000 * PRICE_UNIT);

        (uint256 quotedRepay, uint256 quotedCollateral) =
            riskEngine.liquidationQuote(borrower, address(weth), address(usdc), type(uint256).max);
        assertEq(quotedRepay, 5000 * USDC_UNIT);
        assertEq(quotedCollateral, 5.25 ether);

        usdc.mint(liquidator, quotedRepay);
        _approvePool(liquidator, usdc, quotedRepay);

        vm.prank(liquidator);
        (uint256 paid, uint256 seizedShares) =
            pool.liquidate(address(weth), address(usdc), borrower, type(uint256).max);

        assertEq(paid, quotedRepay);
        assertEq(seizedShares, quotedCollateral);
        assertEq(pool.borrowBalance(address(usdc), borrower), 5000 * USDC_UNIT);
        assertEq(kWeth.balanceOf(liquidator), seizedShares);
        assertEq(kWeth.balanceOf(borrower), 10 ether - seizedShares);
    }

    function testSupplyTokenTransferKeepsHealthyPosition() public {
        _openPosition(10 ether, 10_000 * USDC_UNIT);

        vm.prank(borrower);
        bool transferred = kWeth.transfer(recipient, 1 ether);

        assertTrue(transferred);
        assertEq(kWeth.balanceOf(recipient), 1 ether);
        assertEq(kWeth.balanceOf(borrower), 9 ether);
        assertFalse(riskEngine.isLiquidatable(borrower));
    }

    function testFullSupplyTokenTransferAfterAccrual() public {
        _supply(recipient, usdc, 1000 * USDC_UNIT, recipient);
        _openPosition(100 ether, 100_000 * USDC_UNIT);

        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest(address(usdc));

        uint256 shares = kUsdc.balanceOf(recipient);
        vm.prank(recipient);
        bool transferred = kUsdc.transfer(supplier, shares);

        assertTrue(transferred);
        assertEq(kUsdc.balanceOf(recipient), 0);
        assertEq(kUsdc.balanceOf(supplier), 2_000_000 * USDC_UNIT + shares);
    }

    function testSupplyTokenTransferRejectsUnsafeCollateralReduction() public {
        _openPosition(10 ether, 15_000 * USDC_UNIT);
        uint256 borrowerShares = kWeth.balanceOf(borrower);

        vm.prank(borrower);
        (bool success, bytes memory revertData) =
            address(kWeth).call(abi.encodeCall(IERC20.transfer, (recipient, 1 ether)));

        assertFalse(success);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(revertData), KairoRiskEngine.UnsafeCollateralReduction.selector);
        assertEq(kWeth.balanceOf(borrower), borrowerShares);
        assertEq(kWeth.balanceOf(recipient), 0);
    }

    function testTransferFromUsesAllowanceAndRiskValidation() public {
        _openPosition(10 ether, 8000 * USDC_UNIT);

        vm.prank(borrower);
        kWeth.approve(recipient, 2 ether);
        vm.prank(recipient);
        bool transferred = kWeth.transferFrom(borrower, recipient, 2 ether);

        assertTrue(transferred);
        assertEq(kWeth.allowance(borrower, recipient), 0);
        assertEq(kWeth.balanceOf(recipient), 2 ether);
    }
}
