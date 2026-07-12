// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IPriceFeed
/// @notice Price source for a single market asset.
interface IPriceFeed {
    /// @notice Number of decimals used by returned prices.
    function decimals() external view returns (uint8);

    /// @notice Human-readable feed description.
    function description() external view returns (string memory);

    /// @notice Returns the latest positive price and its observation timestamp.
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
}
