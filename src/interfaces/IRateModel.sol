// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IRateModel
/// @notice Computes per-second rates in ray precision from market liquidity.
interface IRateModel {
    /// @return borrowRateRay Per-second borrower rate, scaled by 1e27.
    function getBorrowRate(
        uint256 cash,
        uint256 totalBorrows,
        uint256 totalReserves
    ) external view returns (uint256 borrowRateRay);

    /// @return supplyRateRay Per-second supplier rate after protocol reserves, scaled by 1e27.
    function getSupplyRate(
        uint256 cash,
        uint256 totalBorrows,
        uint256 totalReserves,
        uint256 reserveFactorBps
    ) external view returns (uint256 supplyRateRay);
}
