// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { MarketMath } from "../libraries/MarketMath.sol";
import { PercentageMath } from "../libraries/PercentageMath.sol";

/// @title KairoStressEngine
/// @notice Deterministic market and portfolio stress calculations for governance tooling.
/// @dev The engine is stateless and does not read protocol storage or token balances.
contract KairoStressEngine {
    using PercentageMath for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant RAY = 1e27;

    error EmptyPortfolio();
    error InvalidScenario();
    error InvalidSnapshot(uint256 index);
    error ArithmeticOverflow();

    struct MarketSnapshot {
        address asset;
        uint256 cash;
        uint256 totalSupplyAssets;
        uint256 totalBorrowAssets;
        uint256 totalReserves;
        uint256 supplyCap;
        uint256 borrowCap;
    }

    struct StressScenario {
        uint16 liquidityOutflowBps;
        uint16 borrowerDefaultBps;
        uint16 recoveryBps;
        uint16 liquidationCostBps;
        uint16 reserveHaircutBps;
        uint16 minimumCoverageBps;
        uint16 minimumLiquidCashBps;
        uint16 concentrationLimitBps;
    }

    struct MarketStress {
        address asset;
        uint256 stressedCash;
        uint256 performingDebt;
        uint256 defaultedDebt;
        uint256 grossRecoveries;
        uint256 liquidationCosts;
        uint256 recoverableDebt;
        uint256 creditLoss;
        uint256 usableReserves;
        uint256 reserveAbsorption;
        uint256 supplierLoss;
        uint256 stressedSupplierAssets;
        uint256 supplierCoverageBps;
        uint256 liquidCashBps;
        uint256 stressedUtilizationRay;
        uint256 supplyCapHeadroom;
        uint256 borrowCapHeadroom;
        uint256 insolvencyGap;
        bool coveragePass;
        bool liquidityPass;
    }

    struct PortfolioStress {
        uint256 totalCash;
        uint256 totalSupplyAssets;
        uint256 totalBorrowAssets;
        uint256 totalStressedSupplierAssets;
        uint256 totalCreditLoss;
        uint256 totalReserveAbsorption;
        uint256 totalSupplierLoss;
        uint256 totalInsolvencyGap;
        uint256 coverageBps;
        uint256 liquidCashBps;
        uint256 largestBorrowMarketBps;
        uint256 weightedUtilizationRay;
        uint256 marketsBelowCoverage;
        uint256 marketsBelowLiquidity;
        bool coveragePass;
        bool liquidityPass;
        bool concentrationPass;
    }

    function evaluateMarket(
        MarketSnapshot memory snapshot,
        StressScenario memory scenario
    ) public pure returns (MarketStress memory result) {
        _validateScenario(scenario);
        _validateSnapshot(snapshot, 0);

        result.asset = snapshot.asset;
        result.stressedCash = _applyInverseBps(snapshot.cash, scenario.liquidityOutflowBps);
        result.performingDebt =
            _applyInverseBps(snapshot.totalBorrowAssets, scenario.borrowerDefaultBps);
        result.defaultedDebt = snapshot.totalBorrowAssets - result.performingDebt;
        result.grossRecoveries = result.defaultedDebt.percentMul(scenario.recoveryBps);
        result.liquidationCosts = result.grossRecoveries.percentMul(scenario.liquidationCostBps);
        result.recoverableDebt = result.performingDebt + result.grossRecoveries;
        if (result.liquidationCosts > result.recoverableDebt) revert ArithmeticOverflow();
        result.recoverableDebt -= result.liquidationCosts;

        result.creditLoss = snapshot.totalBorrowAssets - result.recoverableDebt;
        result.usableReserves = _applyInverseBps(snapshot.totalReserves, scenario.reserveHaircutBps);
        result.reserveAbsorption = _min(result.creditLoss, result.usableReserves);
        result.supplierLoss = result.creditLoss - result.reserveAbsorption;
        result.stressedSupplierAssets = snapshot.totalSupplyAssets > result.supplierLoss
            ? snapshot.totalSupplyAssets - result.supplierLoss
            : 0;

        result.supplierCoverageBps =
            _ratioBps(result.stressedSupplierAssets, snapshot.totalSupplyAssets);
        result.liquidCashBps = _ratioBps(result.stressedCash, snapshot.totalSupplyAssets);
        result.stressedUtilizationRay = MarketMath.utilizationRate(
            result.stressedCash, result.recoverableDebt, result.usableReserves
        );
        result.supplyCapHeadroom = snapshot.supplyCap > snapshot.totalSupplyAssets
            ? snapshot.supplyCap - snapshot.totalSupplyAssets
            : 0;
        result.borrowCapHeadroom = snapshot.borrowCap > snapshot.totalBorrowAssets
            ? snapshot.borrowCap - snapshot.totalBorrowAssets
            : 0;
        result.insolvencyGap = snapshot.totalSupplyAssets > result.stressedSupplierAssets
            ? snapshot.totalSupplyAssets - result.stressedSupplierAssets
            : 0;
        result.coveragePass = result.supplierCoverageBps >= scenario.minimumCoverageBps;
        result.liquidityPass = result.liquidCashBps >= scenario.minimumLiquidCashBps;
    }

    function evaluatePortfolio(
        MarketSnapshot[] memory snapshots,
        StressScenario memory scenario
    ) external pure returns (PortfolioStress memory portfolio, MarketStress[] memory markets) {
        if (snapshots.length == 0) revert EmptyPortfolio();
        _validateScenario(scenario);

        markets = new MarketStress[](snapshots.length);
        uint256 weightedUtilization = 0;
        uint256 largestBorrow = 0;

        for (uint256 i; i < snapshots.length; ++i) {
            _validateSnapshot(snapshots[i], i);
            MarketStress memory market = evaluateMarket(snapshots[i], scenario);
            markets[i] = market;

            portfolio.totalCash = _add(portfolio.totalCash, snapshots[i].cash);
            portfolio.totalSupplyAssets =
                _add(portfolio.totalSupplyAssets, snapshots[i].totalSupplyAssets);
            portfolio.totalBorrowAssets =
                _add(portfolio.totalBorrowAssets, snapshots[i].totalBorrowAssets);
            portfolio.totalStressedSupplierAssets =
                _add(portfolio.totalStressedSupplierAssets, market.stressedSupplierAssets);
            portfolio.totalCreditLoss = _add(portfolio.totalCreditLoss, market.creditLoss);
            portfolio.totalReserveAbsorption =
                _add(portfolio.totalReserveAbsorption, market.reserveAbsorption);
            portfolio.totalSupplierLoss = _add(portfolio.totalSupplierLoss, market.supplierLoss);
            portfolio.totalInsolvencyGap = _add(portfolio.totalInsolvencyGap, market.insolvencyGap);

            uint256 weighted = market.stressedUtilizationRay * snapshots[i].totalBorrowAssets;
            if (
                snapshots[i].totalBorrowAssets != 0
                    && weighted / snapshots[i].totalBorrowAssets != market.stressedUtilizationRay
            ) revert ArithmeticOverflow();
            weightedUtilization = _add(weightedUtilization, weighted);
            largestBorrow = _max(largestBorrow, snapshots[i].totalBorrowAssets);
            if (!market.coveragePass) ++portfolio.marketsBelowCoverage;
            if (!market.liquidityPass) ++portfolio.marketsBelowLiquidity;
        }

        portfolio.coverageBps =
            _ratioBps(portfolio.totalStressedSupplierAssets, portfolio.totalSupplyAssets);
        portfolio.liquidCashBps = _ratioBps(
            _applyInverseBps(portfolio.totalCash, scenario.liquidityOutflowBps),
            portfolio.totalSupplyAssets
        );
        portfolio.largestBorrowMarketBps = _ratioBps(largestBorrow, portfolio.totalBorrowAssets);
        if (portfolio.totalBorrowAssets != 0) {
            portfolio.weightedUtilizationRay = weightedUtilization / portfolio.totalBorrowAssets;
        }
        portfolio.coveragePass = portfolio.coverageBps >= scenario.minimumCoverageBps;
        portfolio.liquidityPass = portfolio.liquidCashBps >= scenario.minimumLiquidCashBps;
        portfolio.concentrationPass =
            portfolio.largestBorrowMarketBps <= scenario.concentrationLimitBps;
    }

    function scenarioId(
        StressScenario memory scenario
    ) external pure returns (bytes32) {
        _validateScenario(scenario);
        return keccak256(abi.encode(scenario));
    }

    function _validateScenario(
        StressScenario memory scenario
    ) internal pure {
        if (
            scenario.liquidityOutflowBps > BPS || scenario.borrowerDefaultBps > BPS
                || scenario.recoveryBps > BPS || scenario.liquidationCostBps > BPS
                || scenario.reserveHaircutBps > BPS || scenario.minimumCoverageBps > BPS
                || scenario.minimumLiquidCashBps > BPS || scenario.concentrationLimitBps == 0
                || scenario.concentrationLimitBps > BPS
        ) revert InvalidScenario();
    }

    function _validateSnapshot(
        MarketSnapshot memory snapshot,
        uint256 index
    ) internal pure {
        if (
            snapshot.asset == address(0) || snapshot.totalReserves > snapshot.cash
                || snapshot.totalSupplyAssets > snapshot.supplyCap
                || snapshot.totalBorrowAssets > snapshot.borrowCap
        ) revert InvalidSnapshot(index);
    }

    function _applyInverseBps(
        uint256 amount,
        uint256 reductionBps
    ) internal pure returns (uint256) {
        return amount - amount.percentMul(reductionBps);
    }

    function _ratioBps(
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (uint256) {
        if (denominator == 0) return BPS;
        if (numerator >= denominator) return BPS;
        return numerator * BPS / denominator;
    }

    function _add(
        uint256 left,
        uint256 right
    ) internal pure returns (uint256 result) {
        unchecked {
            result = left + right;
        }
        if (result < left) revert ArithmeticOverflow();
    }

    function _min(
        uint256 left,
        uint256 right
    ) internal pure returns (uint256) {
        return left < right ? left : right;
    }

    function _max(
        uint256 left,
        uint256 right
    ) internal pure returns (uint256) {
        return left > right ? left : right;
    }
}
