// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IPriceFeed } from "../../src/interfaces/IPriceFeed.sol";

/// @title MockPriceFeed
/// @notice Mutable price source used by the Kairo test suite.
contract MockPriceFeed is IPriceFeed {
    uint8 public immutable override decimals;
    string public override description;

    uint256 public price;
    uint256 public updatedAt;

    constructor(
        uint8 decimals_,
        string memory description_,
        uint256 initialPrice_
    ) {
        decimals = decimals_;
        description = description_;
        price = initialPrice_;
        updatedAt = block.timestamp;
    }

    /// @inheritdoc IPriceFeed
    function latestPrice() external view override returns (uint256, uint256) {
        return (price, updatedAt);
    }

    /// @notice Sets a new price and records the current block timestamp.
    function setPrice(
        uint256 newPrice
    ) external {
        price = newPrice;
        updatedAt = block.timestamp;
    }

    /// @notice Sets the observation timestamp without changing the price.
    function setTimestamp(
        uint256 newTimestamp
    ) external {
        updatedAt = newTimestamp;
    }

    /// @notice Sets both price and observation timestamp explicitly.
    function setPriceAndTimestamp(
        uint256 newPrice,
        uint256 newTimestamp
    ) external {
        price = newPrice;
        updatedAt = newTimestamp;
    }
}
