// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { DataTypes } from "./DataTypes.sol";
import { PercentageMath } from "./PercentageMath.sol";
import { WadRayMath } from "./WadRayMath.sol";

/// @title MarketMath
/// @notice Shared calculations for utilization, shares, prices, and account health.
library MarketMath {
    using PercentageMath for uint256;
    using WadRayMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    error InvalidAssetDecimals(uint256 decimals);
    error MarketMathOverflow();
    error DivisionByZero();

    function utilizationRate(
        uint256 cash,
        uint256 totalBorrows,
        uint256 totalReserves
    ) internal pure returns (uint256) {
        if (totalBorrows == 0) return 0;
        uint256 grossLiquidity = cash + totalBorrows;
        if (totalReserves >= grossLiquidity) return RAY;
        uint256 utilization = totalBorrows.rayDiv(grossLiquidity - totalReserves);
        return utilization > RAY ? RAY : utilization;
    }

    function availableLiquidity(
        uint256 cash,
        uint256 totalReserves
    ) internal pure returns (uint256) {
        return cash > totalReserves ? cash - totalReserves : 0;
    }

    function exchangeRate(
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares
    ) internal pure returns (uint256) {
        if (totalSupplyShares == 0) return RAY;
        return totalSupplyAssets.rayDiv(totalSupplyShares);
    }

    function assetsToShares(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares,
        bool roundUp
    ) internal pure returns (uint256) {
        if (assets == 0) return 0;
        if (totalAssets == 0 || totalShares == 0) return assets;
        return _mulDiv(assets, totalShares, totalAssets, roundUp);
    }

    function sharesToAssets(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares,
        bool roundUp
    ) internal pure returns (uint256) {
        if (shares == 0) return 0;
        if (totalShares == 0) return shares;
        return _mulDiv(shares, totalAssets, totalShares, roundUp);
    }

    /// @notice Converts underlying units into an 18-decimal quote value.
    function valueInQuote(
        uint256 amount,
        uint256 priceWad,
        uint256 assetDecimals
    ) internal pure returns (uint256) {
        if (assetDecimals > 36) revert InvalidAssetDecimals(assetDecimals);
        uint256 unit = 10 ** assetDecimals;
        return _mulDiv(amount, priceWad, unit, false);
    }

    function amountFromQuote(
        uint256 valueWad,
        uint256 priceWad,
        uint256 assetDecimals,
        bool roundUp
    ) internal pure returns (uint256) {
        if (assetDecimals > 36) revert InvalidAssetDecimals(assetDecimals);
        return _mulDiv(valueWad, 10 ** assetDecimals, priceWad, roundUp);
    }

    function reserveAccrual(
        uint256 accruedInterest,
        uint256 reserveFactorBps
    ) internal pure returns (uint256) {
        return accruedInterest.percentMulDown(reserveFactorBps);
    }

    function supplyRate(
        uint256 borrowRateRay,
        uint256 utilizationRay,
        uint256 reserveFactorBps
    ) internal pure returns (uint256) {
        uint256 grossRate = borrowRateRay.rayMul(utilizationRay);
        return grossRate.percentMulDown(PercentageMath.complement(reserveFactorBps));
    }

    function healthFactor(
        uint256 liquidationThresholdValue,
        uint256 debtValue
    ) internal pure returns (uint256) {
        if (debtValue == 0) return type(uint256).max;
        return liquidationThresholdValue.wadDiv(debtValue);
    }

    function accountLiquidity(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 borrowCapacity,
        uint256 liquidationThresholdValue
    ) internal pure returns (DataTypes.AccountLiquidity memory result) {
        uint256 available = borrowCapacity > debtValue ? borrowCapacity - debtValue : 0;
        uint256 shortfall =
            debtValue > liquidationThresholdValue ? debtValue - liquidationThresholdValue : 0;
        result = DataTypes.AccountLiquidity({
            collateralValue: collateralValue,
            debtValue: debtValue,
            borrowCapacity: borrowCapacity,
            liquidationThresholdValue: liquidationThresholdValue,
            availableBorrows: available,
            healthFactor: healthFactor(liquidationThresholdValue, debtValue),
            shortfall: shortfall
        });
    }

    function _mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator,
        bool roundUp
    ) private pure returns (uint256 result) {
        if (denominator == 0) revert DivisionByZero();
        if (x != 0 && y > type(uint256).max / x) revert MarketMathOverflow();
        uint256 product = x * y;
        result = product / denominator;
        if (roundUp && product % denominator != 0) {
            if (result == type(uint256).max) revert MarketMathOverflow();
            result += 1;
        }
    }
}
