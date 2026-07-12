// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ITransferValidator
/// @notice Validates supply-token transfers against protocol risk constraints.
interface ITransferValidator {
    /// @dev Must revert when the transfer would leave `from` below required collateralization.
    /// Balances are supplied before mutation so implementations can evaluate the resulting state.
    function validateSupplyTokenTransfer(
        address asset,
        address from,
        address to,
        uint256 amount,
        uint256 fromBalanceBefore,
        uint256 toBalanceBefore
    ) external view;
}
