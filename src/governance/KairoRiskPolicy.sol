// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { DataTypes } from "../libraries/DataTypes.sol";

/// @title KairoRiskPolicy
/// @notice Pure policy assessment for proposed market configuration changes.
contract KairoRiskPolicy {
    uint256 public constant BPS = 10_000;

    uint256 public constant FLAG_LTV_INCREASE = 1 << 0;
    uint256 public constant FLAG_LIQUIDATION_THRESHOLD_DECREASE = 1 << 1;
    uint256 public constant FLAG_LIQUIDATION_BONUS_INCREASE = 1 << 2;
    uint256 public constant FLAG_RESERVE_FACTOR_DECREASE = 1 << 3;
    uint256 public constant FLAG_CLOSE_FACTOR_INCREASE = 1 << 4;
    uint256 public constant FLAG_SUPPLY_CAP_INCREASE = 1 << 5;
    uint256 public constant FLAG_BORROW_CAP_INCREASE = 1 << 6;
    uint256 public constant FLAG_ORACLE_AGE_INCREASE = 1 << 7;
    uint256 public constant FLAG_SOURCE_CHANGE = 1 << 8;
    uint256 public constant FLAG_RATE_MODEL_CHANGE = 1 << 9;

    error InvalidPolicyBounds();

    enum ReviewTier {
        Routine,
        Risk,
        Treasury,
        Governance
    }

    struct PolicyBounds {
        uint16 maxLoanToValueBps;
        uint16 minLiquidationGapBps;
        uint16 maxLiquidationBonusBps;
        uint16 minReserveFactorBps;
        uint16 maxCloseFactorBps;
        uint16 maxBorrowToSupplyCapBps;
        uint40 maxPriceAge;
    }

    struct Assessment {
        bool structurallyValid;
        bool withinPolicy;
        ReviewTier reviewTier;
        uint256 changeFlags;
        uint256 liquidationGapBps;
        uint256 borrowToSupplyCapBps;
    }

    function assess(
        DataTypes.MarketConfig memory current,
        DataTypes.MarketConfig memory proposed,
        PolicyBounds memory bounds
    ) external pure returns (Assessment memory result) {
        _validateBounds(bounds);

        result.structurallyValid = _structurallyValid(proposed);
        if (!result.structurallyValid) {
            result.reviewTier = ReviewTier.Governance;
            return result;
        }

        result.liquidationGapBps =
            uint256(proposed.liquidationThresholdBps) - proposed.loanToValueBps;
        result.borrowToSupplyCapBps = uint256(proposed.borrowCap) * BPS / proposed.supplyCap;
        result.withinPolicy = proposed.loanToValueBps <= bounds.maxLoanToValueBps
            && result.liquidationGapBps >= bounds.minLiquidationGapBps
            && proposed.liquidationBonusBps <= bounds.maxLiquidationBonusBps
            && proposed.reserveFactorBps >= bounds.minReserveFactorBps
            && proposed.closeFactorBps <= bounds.maxCloseFactorBps
            && result.borrowToSupplyCapBps <= bounds.maxBorrowToSupplyCapBps
            && proposed.priceMaxAge <= bounds.maxPriceAge;

        result.changeFlags = _changeFlags(current, proposed);
        result.reviewTier = _reviewTier(result.changeFlags, result.withinPolicy);
    }

    function policyId(
        PolicyBounds memory bounds
    ) external pure returns (bytes32) {
        _validateBounds(bounds);
        return keccak256(abi.encode(bounds));
    }

    function _structurallyValid(
        DataTypes.MarketConfig memory config
    ) internal pure returns (bool) {
        return config.supplyToken != address(0) && config.priceFeed != address(0)
            && config.rateModel != address(0) && config.supplyCap != 0
            && config.borrowCap <= config.supplyCap
            && config.loanToValueBps <= config.liquidationThresholdBps
            && config.liquidationThresholdBps <= BPS && config.liquidationBonusBps <= 5000
            && config.reserveFactorBps <= BPS && config.closeFactorBps != 0
            && config.closeFactorBps <= BPS && config.priceMaxAge != 0 && config.assetDecimals <= 36;
    }

    function _changeFlags(
        DataTypes.MarketConfig memory current,
        DataTypes.MarketConfig memory proposed
    ) internal pure returns (uint256 flags) {
        if (proposed.loanToValueBps > current.loanToValueBps) flags |= FLAG_LTV_INCREASE;
        if (proposed.liquidationThresholdBps < current.liquidationThresholdBps) {
            flags |= FLAG_LIQUIDATION_THRESHOLD_DECREASE;
        }
        if (proposed.liquidationBonusBps > current.liquidationBonusBps) {
            flags |= FLAG_LIQUIDATION_BONUS_INCREASE;
        }
        if (proposed.reserveFactorBps < current.reserveFactorBps) {
            flags |= FLAG_RESERVE_FACTOR_DECREASE;
        }
        if (proposed.closeFactorBps > current.closeFactorBps) {
            flags |= FLAG_CLOSE_FACTOR_INCREASE;
        }
        if (proposed.supplyCap > current.supplyCap) flags |= FLAG_SUPPLY_CAP_INCREASE;
        if (proposed.borrowCap > current.borrowCap) flags |= FLAG_BORROW_CAP_INCREASE;
        if (proposed.priceMaxAge > current.priceMaxAge) flags |= FLAG_ORACLE_AGE_INCREASE;
        if (proposed.priceFeed != current.priceFeed) flags |= FLAG_SOURCE_CHANGE;
        if (proposed.rateModel != current.rateModel) flags |= FLAG_RATE_MODEL_CHANGE;
    }

    function _reviewTier(
        uint256 flags,
        bool withinPolicy
    ) internal pure returns (ReviewTier) {
        if (!withinPolicy || flags & (FLAG_SOURCE_CHANGE | FLAG_RATE_MODEL_CHANGE) != 0) {
            return ReviewTier.Governance;
        }
        if (
            flags
                    & (FLAG_LTV_INCREASE
                        | FLAG_LIQUIDATION_THRESHOLD_DECREASE
                        | FLAG_LIQUIDATION_BONUS_INCREASE
                        | FLAG_CLOSE_FACTOR_INCREASE) != 0
        ) return ReviewTier.Risk;
        if (
            flags
                    & (FLAG_RESERVE_FACTOR_DECREASE
                        | FLAG_SUPPLY_CAP_INCREASE
                        | FLAG_BORROW_CAP_INCREASE) != 0
        ) return ReviewTier.Treasury;
        return ReviewTier.Routine;
    }

    function _validateBounds(
        PolicyBounds memory bounds
    ) internal pure {
        if (
            bounds.maxLoanToValueBps > BPS || bounds.minLiquidationGapBps > BPS
                || bounds.maxLiquidationBonusBps > BPS || bounds.minReserveFactorBps > BPS
                || bounds.maxCloseFactorBps == 0 || bounds.maxCloseFactorBps > BPS
                || bounds.maxBorrowToSupplyCapBps == 0 || bounds.maxBorrowToSupplyCapBps > BPS
                || bounds.maxPriceAge == 0
        ) revert InvalidPolicyBounds();
    }
}
