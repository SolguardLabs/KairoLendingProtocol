// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { DataTypes } from "../libraries/DataTypes.sol";

/// @title IKairoPoolView
/// @notice Read-only surface used by integrations and monitoring systems.
interface IKairoPoolView {
    function marketCount() external view returns (uint256);
    function marketAt(
        uint256 index
    ) external view returns (address asset);

    function getMarketConfig(
        address asset
    ) external view returns (DataTypes.MarketConfig memory);
    function getMarketState(
        address asset
    ) external view returns (DataTypes.MarketState memory);
    function getDebtPosition(
        address asset,
        address account
    ) external view returns (DataTypes.DebtPosition memory);
    function getAccountLiquidity(
        address account
    ) external view returns (DataTypes.AccountLiquidity memory);

    function borrowBalance(
        address asset,
        address account
    ) external view returns (uint256);
    function supplyBalance(
        address asset,
        address account
    ) external view returns (uint256);
    function previewBorrowIndex(
        address asset
    ) external view returns (uint256);
    function isMarketActive(
        address asset
    ) external view returns (bool);
}
