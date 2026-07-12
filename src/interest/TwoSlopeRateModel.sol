// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IRateModel } from "../interfaces/IRateModel.sol";
import { MarketMath } from "../libraries/MarketMath.sol";
import { PercentageMath } from "../libraries/PercentageMath.sol";
import { WadRayMath } from "../libraries/WadRayMath.sol";

/// @title TwoSlopeRateModel
/// @notice Immutable kinked interest-rate curve driven by market utilization.
contract TwoSlopeRateModel is IRateModel {
    using PercentageMath for uint256;
    using WadRayMath for uint256;

    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public immutable optimalUtilizationRay;
    uint256 public immutable baseRatePerSecondRay;
    uint256 public immutable slope1PerSecondRay;
    uint256 public immutable slope2PerSecondRay;

    error InvalidOptimalUtilization(uint256 utilization);
    error InvalidUtilization(uint256 utilization);
    error InvalidReserveFactor(uint256 reserveFactorBps);
    error RateOverflow();

    constructor(
        uint256 optimalUtilizationRay_,
        uint256 baseRatePerSecondRay_,
        uint256 slope1PerSecondRay_,
        uint256 slope2PerSecondRay_
    ) {
        if (optimalUtilizationRay_ == 0 || optimalUtilizationRay_ >= RAY) {
            revert InvalidOptimalUtilization(optimalUtilizationRay_);
        }
        if (
            baseRatePerSecondRay_ > type(uint256).max - slope1PerSecondRay_
                || baseRatePerSecondRay_ + slope1PerSecondRay_
                    > type(uint256).max - slope2PerSecondRay_
        ) revert RateOverflow();

        optimalUtilizationRay = optimalUtilizationRay_;
        baseRatePerSecondRay = baseRatePerSecondRay_;
        slope1PerSecondRay = slope1PerSecondRay_;
        slope2PerSecondRay = slope2PerSecondRay_;
    }

    function getBorrowRate(
        uint256 cash,
        uint256 totalBorrows,
        uint256 totalReserves
    ) external view override returns (uint256) {
        return rateAtUtilization(MarketMath.utilizationRate(cash, totalBorrows, totalReserves));
    }

    function getSupplyRate(
        uint256 cash,
        uint256 totalBorrows,
        uint256 totalReserves,
        uint256 reserveFactorBps
    ) external view override returns (uint256) {
        if (reserveFactorBps > PercentageMath.BPS) revert InvalidReserveFactor(reserveFactorBps);
        uint256 utilization = MarketMath.utilizationRate(cash, totalBorrows, totalReserves);
        return MarketMath.supplyRate(rateAtUtilization(utilization), utilization, reserveFactorBps);
    }

    function rateAtUtilization(
        uint256 utilizationRay
    ) public view returns (uint256) {
        if (utilizationRay > RAY) revert InvalidUtilization(utilizationRay);

        if (utilizationRay <= optimalUtilizationRay) {
            uint256 normalized = utilizationRay.rayDiv(optimalUtilizationRay);
            return baseRatePerSecondRay + slope1PerSecondRay.rayMul(normalized);
        }

        uint256 excessUtilization = utilizationRay - optimalUtilizationRay;
        uint256 excessRange = RAY - optimalUtilizationRay;
        uint256 normalizedExcess = excessUtilization.rayDiv(excessRange);
        return
            baseRatePerSecondRay + slope1PerSecondRay + slope2PerSecondRay.rayMul(normalizedExcess);
    }

    function maximumBorrowRate() external view returns (uint256) {
        return baseRatePerSecondRay + slope1PerSecondRay + slope2PerSecondRay;
    }

    function annualizedBorrowRate(
        uint256 utilizationRay
    ) external view returns (uint256) {
        uint256 perSecondRate = rateAtUtilization(utilizationRay);
        if (perSecondRate > type(uint256).max / SECONDS_PER_YEAR) revert RateOverflow();
        return perSecondRate * SECONDS_PER_YEAR;
    }
}
