// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title DataTypes
/// @notice Shared storage and return types for Kairo markets.
library DataTypes {
    /// @notice Administrative lifecycle of a listed market.
    enum MarketStatus {
        Unlisted,
        Active,
        Frozen,
        Deprecated
    }

    /// @notice Risk and integration parameters for one underlying asset.
    /// @dev Ratios use basis points. Caps and accounting values use underlying units.
    struct MarketConfig {
        address supplyToken;
        address priceFeed;
        address rateModel;
        uint128 supplyCap;
        uint128 borrowCap;
        uint40 priceMaxAge;
        uint16 loanToValueBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationBonusBps;
        uint16 reserveFactorBps;
        uint16 closeFactorBps;
        uint8 assetDecimals;
        MarketStatus status;
        bool borrowingEnabled;
    }

    /// @notice Aggregate interest and liquidity accounting for one market.
    /// @dev Indices are ray-scaled and start at 1e27.
    struct MarketState {
        uint128 totalSupplyAssets;
        uint128 totalBorrowAssets;
        uint128 totalReserves;
        uint128 borrowIndex;
        uint128 supplyIndex;
        uint40 lastAccrual;
    }

    /// @notice Borrower debt checkpoint for a single market.
    /// @dev `principal` is denominated in underlying units at `interestIndex`.
    struct DebtPosition {
        uint128 principal;
        uint128 interestIndex;
        uint40 lastUpdate;
    }

    /// @notice Aggregated account values expressed in the protocol quote currency.
    struct AccountLiquidity {
        uint256 collateralValue;
        uint256 debtValue;
        uint256 borrowCapacity;
        uint256 liquidationThresholdValue;
        uint256 availableBorrows;
        uint256 healthFactor;
        uint256 shortfall;
    }
}
