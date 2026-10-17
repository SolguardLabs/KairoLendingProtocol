// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { KairoLendingPool } from "../../src/KairoLendingPool.sol";
import { TwoSlopeRateModel } from "../../src/interest/TwoSlopeRateModel.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { IKairoPoolView } from "../../src/interfaces/IKairoPoolView.sol";
import { KairoProtocolLens } from "../../src/lens/KairoProtocolLens.sol";
import { DataTypes } from "../../src/libraries/DataTypes.sol";
import { KairoOracleRouter } from "../../src/oracle/KairoOracleRouter.sol";
import { KairoRiskEngine } from "../../src/risk/KairoRiskEngine.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPriceFeed } from "../mocks/MockPriceFeed.sol";

abstract contract KairoTestBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant PRICE_UNIT = 1e8;
    uint256 internal constant USDC_UNIT = 1e6;

    uint256 internal constant OPTIMAL_UTILIZATION = 8e26;
    uint256 internal constant BASE_RATE = 1e18;
    uint256 internal constant SLOPE_ONE = 2e18;
    uint256 internal constant SLOPE_TWO = 8e18;

    uint128 internal constant WETH_SUPPLY_CAP = 1_000_000 ether;
    uint128 internal constant WETH_BORROW_CAP = 500_000 ether;
    uint128 internal constant USDC_SUPPLY_CAP = 10_000_000 * 1e6;
    uint128 internal constant USDC_BORROW_CAP = 8_000_000 * 1e6;

    address internal admin;
    address internal treasury;
    address internal supplier;
    address internal borrower;
    address internal liquidator;
    address internal recipient;

    MockERC20 internal weth;
    MockERC20 internal usdc;

    MockPriceFeed internal wethPrimary;
    MockPriceFeed internal usdcPrimary;
    KairoOracleRouter internal wethOracle;
    KairoOracleRouter internal usdcOracle;

    TwoSlopeRateModel internal rateModel;
    KairoLendingPool internal pool;
    KairoProtocolLens internal lens;
    KairoRiskEngine internal riskEngine;

    IERC20 internal kWeth;
    IERC20 internal kUsdc;

    function setUp() public virtual {
        vm.warp(1_800_000_000);

        admin = address(this);
        treasury = makeAddr("treasury");
        supplier = makeAddr("supplier");
        borrower = makeAddr("borrower");
        liquidator = makeAddr("liquidator");
        recipient = makeAddr("recipient");

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        wethPrimary = new MockPriceFeed(8, "WETH / USD", 2000 * PRICE_UNIT);
        usdcPrimary = new MockPriceFeed(8, "USDC / USD", PRICE_UNIT);

        wethOracle = _router(address(wethPrimary), address(0), "Kairo WETH / USD");
        usdcOracle = _router(address(usdcPrimary), address(0), "Kairo USDC / USD");

        rateModel = new TwoSlopeRateModel(OPTIMAL_UTILIZATION, BASE_RATE, SLOPE_ONE, SLOPE_TWO);
        pool = new KairoLendingPool(admin, treasury);
        riskEngine = new KairoRiskEngine(IKairoPoolView(address(pool)));
        pool.setRiskEngine(address(riskEngine));
        lens = new KairoProtocolLens(IKairoPoolView(address(pool)));

        pool.listMarket(
            address(weth),
            "Kairo WETH",
            "kWETH",
            _marketConfig(address(wethOracle), WETH_SUPPLY_CAP, WETH_BORROW_CAP, 7500, 8000)
        );
        pool.listMarket(
            address(usdc),
            "Kairo USDC",
            "kUSDC",
            _marketConfig(address(usdcOracle), USDC_SUPPLY_CAP, USDC_BORROW_CAP, 8500, 9000)
        );

        kWeth = IERC20(pool.getMarketConfig(address(weth)).supplyToken);
        kUsdc = IERC20(pool.getMarketConfig(address(usdc)).supplyToken);

        _supply(supplier, usdc, 2_000_000 * USDC_UNIT, supplier);
    }

    function _router(
        address primary,
        address fallbackSource,
        string memory description
    ) internal returns (KairoOracleRouter) {
        return new KairoOracleRouter(admin, primary, fallbackSource, 1 days, 500, 8, description);
    }

    function _marketConfig(
        address priceFeed,
        uint128 supplyCap,
        uint128 borrowCap,
        uint16 loanToValueBps,
        uint16 liquidationThresholdBps
    ) internal view returns (DataTypes.MarketConfig memory config) {
        config = DataTypes.MarketConfig({
            supplyToken: address(0),
            priceFeed: priceFeed,
            rateModel: address(rateModel),
            supplyCap: supplyCap,
            borrowCap: borrowCap,
            priceMaxAge: 2 days,
            loanToValueBps: loanToValueBps,
            liquidationThresholdBps: liquidationThresholdBps,
            liquidationBonusBps: 500,
            reserveFactorBps: 1000,
            closeFactorBps: 5000,
            assetDecimals: 0,
            status: DataTypes.MarketStatus.Unlisted,
            borrowingEnabled: true
        });
    }

    function _supply(
        address payer,
        MockERC20 asset,
        uint256 amount,
        address beneficiary
    ) internal returns (uint256 shares) {
        asset.mint(payer, amount);
        vm.startPrank(payer);
        asset.approve(address(pool), amount);
        shares = pool.supply(address(asset), amount, beneficiary);
        vm.stopPrank();
    }

    function _supplyCollateral(
        address account,
        uint256 amount
    ) internal returns (uint256 shares) {
        return _supply(account, weth, amount, account);
    }

    function _borrow(
        address account,
        uint256 amount
    ) internal returns (uint256 accountDebt) {
        vm.prank(account);
        accountDebt = pool.borrow(address(usdc), amount, account);
    }

    function _openPosition(
        uint256 collateralAmount,
        uint256 borrowAmount
    ) internal {
        _supplyCollateral(borrower, collateralAmount);
        _borrow(borrower, borrowAmount);
    }

    function _approvePool(
        address account,
        MockERC20 asset,
        uint256 amount
    ) internal {
        vm.prank(account);
        asset.approve(address(pool), amount);
    }
}
