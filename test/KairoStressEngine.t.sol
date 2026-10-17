// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { KairoStressEngine } from "../src/risk/KairoStressEngine.sol";

contract KairoStressEngineTest is Test {
    KairoStressEngine internal engine;

    function setUp() public {
        engine = new KairoStressEngine();
    }

    function testMarketStressAllocatesCreditLossThroughReserves() public view {
        KairoStressEngine.MarketStress memory result =
            engine.evaluateMarket(_snapshot(address(1), 500, 1000, 600, 100), _scenario());

        assertEq(result.stressedCash, 400);
        assertEq(result.performingDebt, 450);
        assertEq(result.defaultedDebt, 150);
        assertEq(result.grossRecoveries, 60);
        assertEq(result.liquidationCosts, 6);
        assertEq(result.recoverableDebt, 504);
        assertEq(result.creditLoss, 96);
        assertEq(result.usableReserves, 80);
        assertEq(result.reserveAbsorption, 80);
        assertEq(result.supplierLoss, 16);
        assertEq(result.stressedSupplierAssets, 984);
        assertEq(result.supplierCoverageBps, 9840);
        assertEq(result.liquidCashBps, 4000);
        assertEq(result.insolvencyGap, 16);
        assertTrue(result.coveragePass);
        assertTrue(result.liquidityPass);
    }

    function testMarketStressFlagsCoverageAndLiquidityCorridors() public view {
        KairoStressEngine.StressScenario memory scenario = _scenario();
        scenario.minimumCoverageBps = 9900;
        scenario.minimumLiquidCashBps = 4500;

        KairoStressEngine.MarketStress memory result =
            engine.evaluateMarket(_snapshot(address(1), 500, 1000, 600, 100), scenario);

        assertFalse(result.coveragePass);
        assertFalse(result.liquidityPass);
    }

    function testPortfolioAggregatesMarketsAndConcentration() public view {
        KairoStressEngine.MarketSnapshot[] memory snapshots =
            new KairoStressEngine.MarketSnapshot[](2);
        snapshots[0] = _snapshot(address(1), 500, 1000, 600, 100);
        snapshots[1] = _snapshot(address(2), 1000, 2000, 400, 200);

        (
            KairoStressEngine.PortfolioStress memory portfolio,
            KairoStressEngine.MarketStress[] memory markets
        ) = engine.evaluatePortfolio(snapshots, _scenario());

        assertEq(markets.length, 2);
        assertEq(portfolio.totalCash, 1500);
        assertEq(portfolio.totalSupplyAssets, 3000);
        assertEq(portfolio.totalBorrowAssets, 1000);
        assertEq(portfolio.largestBorrowMarketBps, 6000);
        assertFalse(portfolio.concentrationPass);
        assertEq(portfolio.marketsBelowCoverage, 0);
        assertEq(portfolio.marketsBelowLiquidity, 0);
    }

    function testScenarioIdIsStableAndDomainSensitive() public view {
        KairoStressEngine.StressScenario memory first = _scenario();
        KairoStressEngine.StressScenario memory second = _scenario();
        assertEq(engine.scenarioId(first), engine.scenarioId(second));

        second.recoveryBps += 1;
        assertNotEq(engine.scenarioId(first), engine.scenarioId(second));
    }

    function testRejectsInvalidScenario() public {
        KairoStressEngine.StressScenario memory scenario = _scenario();
        scenario.concentrationLimitBps = 0;
        vm.expectRevert(KairoStressEngine.InvalidScenario.selector);
        engine.evaluateMarket(_snapshot(address(1), 500, 1000, 600, 100), scenario);
    }

    function testRejectsReserveAboveCash() public {
        vm.expectPartialRevert(KairoStressEngine.InvalidSnapshot.selector);
        engine.evaluateMarket(_snapshot(address(1), 100, 1000, 600, 101), _scenario());
    }

    function testEmptyPortfolioIsRejected() public {
        KairoStressEngine.MarketSnapshot[] memory snapshots =
            new KairoStressEngine.MarketSnapshot[](0);
        vm.expectRevert(KairoStressEngine.EmptyPortfolio.selector);
        engine.evaluatePortfolio(snapshots, _scenario());
    }

    function testCapHeadroomSaturatesAtZero() public view {
        KairoStressEngine.MarketSnapshot memory snapshot =
            _snapshot(address(1), 500, 1000, 600, 100);
        snapshot.supplyCap = snapshot.totalSupplyAssets;
        snapshot.borrowCap = snapshot.totalBorrowAssets;
        KairoStressEngine.MarketStress memory result = engine.evaluateMarket(snapshot, _scenario());
        assertEq(result.supplyCapHeadroom, 0);
        assertEq(result.borrowCapHeadroom, 0);
    }

    function _snapshot(
        address asset,
        uint256 cash,
        uint256 supplied,
        uint256 borrowed,
        uint256 reserves
    ) internal pure returns (KairoStressEngine.MarketSnapshot memory) {
        return KairoStressEngine.MarketSnapshot({
            asset: asset,
            cash: cash,
            totalSupplyAssets: supplied,
            totalBorrowAssets: borrowed,
            totalReserves: reserves,
            supplyCap: 10_000,
            borrowCap: 8000
        });
    }

    function _scenario() internal pure returns (KairoStressEngine.StressScenario memory) {
        return KairoStressEngine.StressScenario({
            liquidityOutflowBps: 2000,
            borrowerDefaultBps: 2500,
            recoveryBps: 4000,
            liquidationCostBps: 1000,
            reserveHaircutBps: 2000,
            minimumCoverageBps: 9500,
            minimumLiquidCashBps: 3000,
            concentrationLimitBps: 5000
        });
    }
}
