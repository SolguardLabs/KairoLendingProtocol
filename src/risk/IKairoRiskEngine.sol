// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IKairoPoolView } from "../interfaces/IKairoPoolView.sol";
import { DataTypes } from "../libraries/DataTypes.sol";

/// @title IKairoRiskEngine
/// @notice Solvency checks and liquidation sizing used by the lending pool.
interface IKairoRiskEngine {
    function pool() external view returns (IKairoPoolView);

    function getAccountLiquidity(
        address account
    ) external view returns (DataTypes.AccountLiquidity memory);

    function getHypotheticalAccountLiquidity(
        address account,
        address changedAsset,
        uint256 collateralReduction,
        uint256 borrowIncrease
    ) external view returns (DataTypes.AccountLiquidity memory);

    function validateBorrow(
        address account,
        address asset,
        uint256 amount
    ) external view;

    function validateCollateralReduction(
        address account,
        address asset,
        uint256 assets
    ) external view;

    function isLiquidatable(
        address account
    ) external view returns (bool);

    function liquidationQuote(
        address account,
        address collateralAsset,
        address debtAsset,
        uint256 requestedRepay
    ) external view returns (uint256 repayAssets, uint256 seizeCollateralAssets);
}
