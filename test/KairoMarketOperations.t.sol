// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { KairoLendingPool } from "../src/KairoLendingPool.sol";
import { DataTypes } from "../src/libraries/DataTypes.sol";
import { KairoRiskEngine } from "../src/risk/KairoRiskEngine.sol";
import { KairoTestBase } from "./helpers/KairoTestBase.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPriceFeed } from "./mocks/MockPriceFeed.sol";

contract KairoMarketOperationsTest is KairoTestBase {
    function testMarketListingRecordsConfigurationAndReceiptMetadata() public view {
        assertEq(pool.marketCount(), 2);
        assertEq(pool.marketAt(0), address(weth));
        assertEq(pool.marketAt(1), address(usdc));

        DataTypes.MarketConfig memory config = pool.getMarketConfig(address(weth));
        assertEq(config.priceFeed, address(wethOracle));
        assertEq(config.rateModel, address(rateModel));
        assertEq(config.supplyCap, WETH_SUPPLY_CAP);
        assertEq(config.borrowCap, WETH_BORROW_CAP);
        assertEq(config.assetDecimals, 18);
        assertEq(uint256(config.status), uint256(DataTypes.MarketStatus.Active));
        assertTrue(config.borrowingEnabled);

        assertEq(kWeth.name(), "Kairo WETH");
        assertEq(kWeth.symbol(), "kWETH");
        assertEq(kWeth.decimals(), 18);
    }

    function testConfiguratorCanListAdditionalMarket() public {
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        MockPriceFeed feed = new MockPriceFeed(8, "WBTC / USD", 60_000 * PRICE_UNIT);

        address supplyToken = pool.listMarket(
            address(wbtc),
            "Kairo WBTC",
            "kWBTC",
            _marketConfig(address(feed), 1_000_000e8, 500_000e8, 7000, 7500)
        );

        assertEq(pool.marketCount(), 3);
        assertEq(pool.marketAt(2), address(wbtc));
        assertEq(pool.getMarketConfig(address(wbtc)).supplyToken, supplyToken);
        assertEq(pool.getMarketState(address(wbtc)).borrowIndex, RAY);
    }

    function testCannotListTheSameMarketTwice() public {
        vm.expectPartialRevert(KairoLendingPool.MarketAlreadyListed.selector);
        pool.listMarket(
            address(weth),
            "Second WETH",
            "kWETH2",
            _marketConfig(address(wethOracle), WETH_SUPPLY_CAP, WETH_BORROW_CAP, 7500, 8000)
        );
    }

    function testSupplyMintsSharesToSelectedBeneficiary() public {
        uint256 amount = 25_000 * USDC_UNIT;
        uint256 payerBalanceBefore = usdc.balanceOf(recipient);
        uint256 sharesBefore = kUsdc.balanceOf(borrower);

        uint256 shares = _supply(recipient, usdc, amount, borrower);

        assertEq(shares, amount);
        assertEq(usdc.balanceOf(recipient), payerBalanceBefore);
        assertEq(kUsdc.balanceOf(borrower) - sharesBefore, shares);
        assertEq(pool.supplyBalance(address(usdc), borrower), amount);
    }

    function testWithdrawAndRedeemReturnUnderlyingAssets() public {
        uint256 supplied = 10 ether;
        _supplyCollateral(borrower, supplied);

        vm.startPrank(borrower);
        uint256 burnedForWithdrawal = pool.withdraw(address(weth), 3 ether, recipient);
        uint256 redeemedAssets = pool.redeem(address(weth), 7 ether, recipient);
        vm.stopPrank();

        assertEq(burnedForWithdrawal, 3 ether);
        assertEq(redeemedAssets, 7 ether);
        assertEq(weth.balanceOf(recipient), supplied);
        assertEq(kWeth.balanceOf(borrower), 0);
        assertEq(pool.supplyBalance(address(weth), borrower), 0);
    }

    function testSupplyCapIsEnforced() public {
        uint128 currentSupply = pool.getMarketState(address(usdc)).totalSupplyAssets;
        pool.setMarketCaps(address(usdc), currentSupply + 1000, 1_000_000 * 1e6);

        usdc.mint(recipient, 1001);
        vm.startPrank(recipient);
        usdc.approve(address(pool), 1001);
        vm.expectPartialRevert(KairoLendingPool.SupplyCapExceeded.selector);
        pool.supply(address(usdc), 1001, recipient);
        vm.stopPrank();
    }

    function testBorrowAtLoanToValueLimitAndRejectExcess() public {
        _supplyCollateral(borrower, 10 ether);

        uint256 borrowed = _borrow(borrower, 15_000 * USDC_UNIT);
        assertEq(borrowed, 15_000 * USDC_UNIT);
        assertEq(usdc.balanceOf(borrower), borrowed);

        vm.expectPartialRevert(KairoRiskEngine.InsufficientCollateral.selector);
        vm.prank(borrower);
        pool.borrow(address(usdc), 1, borrower);
    }

    function testBorrowCapIsEnforcedAcrossOperations() public {
        pool.setMarketCaps(address(usdc), USDC_SUPPLY_CAP, 10_000 * 1e6);
        _supplyCollateral(borrower, 20 ether);

        _borrow(borrower, 10_000 * USDC_UNIT);

        vm.expectPartialRevert(KairoLendingPool.BorrowCapExceeded.selector);
        vm.prank(borrower);
        pool.borrow(address(usdc), 1, borrower);
    }

    function testPartialRepaymentUpdatesAccountAndMarketInSameTimestamp() public {
        uint256 borrowed = 50_000 * USDC_UNIT;
        uint256 repayment = 20_000 * USDC_UNIT;
        _openPosition(100 ether, borrowed);
        _approvePool(borrower, usdc, repayment);

        vm.prank(borrower);
        (uint256 paid, uint256 remaining) = pool.repay(address(usdc), repayment, borrower);

        assertEq(paid, repayment);
        assertEq(remaining, borrowed - repayment);
        assertEq(pool.borrowBalance(address(usdc), borrower), borrowed - repayment);
        assertEq(pool.getMarketState(address(usdc)).totalBorrowAssets, borrowed - repayment);
    }

    function testFullRepaymentClearsPositionInSameTimestamp() public {
        uint256 borrowed = 40_000 * USDC_UNIT;
        _openPosition(100 ether, borrowed);
        _approvePool(borrower, usdc, type(uint256).max);

        vm.prank(borrower);
        (uint256 paid, uint256 remaining) = pool.repay(address(usdc), type(uint256).max, borrower);

        DataTypes.DebtPosition memory position = pool.getDebtPosition(address(usdc), borrower);
        assertEq(paid, borrowed);
        assertEq(remaining, 0);
        assertEq(position.principal, 0);
        assertEq(pool.borrowBalance(address(usdc), borrower), 0);
        assertEq(pool.getMarketState(address(usdc)).totalBorrowAssets, 0);
    }

    function testFuzzSupplyAndRedeemRoundTrip(
        uint96 rawAmount
    ) public {
        uint256 amount = bound(uint256(rawAmount), 1e9, 10_000 ether);

        uint256 shares = _supply(recipient, weth, amount, recipient);
        vm.prank(recipient);
        uint256 assets = pool.redeem(address(weth), shares, recipient);

        assertEq(assets, amount);
        assertEq(weth.balanceOf(recipient), amount);
        assertEq(kWeth.balanceOf(recipient), 0);
    }

    function testFuzzPartialRepaymentInSameTimestamp(
        uint64 rawBorrow,
        uint64 rawRepayment
    ) public {
        uint256 borrowed = bound(uint256(rawBorrow), 2, 100_000 * USDC_UNIT);
        uint256 repayment = bound(uint256(rawRepayment), 1, borrowed - 1);
        _openPosition(100 ether, borrowed);
        _approvePool(borrower, usdc, repayment);

        vm.prank(borrower);
        (uint256 paid, uint256 remaining) = pool.repay(address(usdc), repayment, borrower);

        assertEq(paid, repayment);
        assertEq(remaining, borrowed - repayment);
        assertEq(pool.borrowBalance(address(usdc), borrower), remaining);
    }
}
