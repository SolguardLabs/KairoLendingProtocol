// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { KairoLendingPool } from "../KairoLendingPool.sol";
import { ProtocolAccess } from "../core/ProtocolAccess.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @title KairoTreasury
/// @notice Receives protocol reserves and routes approved distributions.
/// @dev The treasury contract must hold TREASURY_ROLE on the pool.
contract KairoTreasury is ProtocolAccess {
    using SafeTransferLib for address;

    KairoLendingPool public immutable pool;
    address public reserveRecipient;

    error InvalidPool();
    error InvalidRecipient();
    error InvalidArrayLength();
    error ArrayLengthMismatch();

    event ReserveRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event MarketReservesCollected(address indexed asset, uint256 amount, address indexed recipient);
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    constructor(
        address initialAdmin,
        KairoLendingPool pool_,
        address initialRecipient
    ) ProtocolAccess(initialAdmin) {
        if (address(pool_) == address(0) || address(pool_).code.length == 0) revert InvalidPool();
        if (initialRecipient == address(0)) revert InvalidRecipient();
        pool = pool_;
        reserveRecipient = initialRecipient;
        emit ReserveRecipientUpdated(address(0), initialRecipient);
    }

    function setReserveRecipient(
        address newRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert InvalidRecipient();
        address previous = reserveRecipient;
        reserveRecipient = newRecipient;
        emit ReserveRecipientUpdated(previous, newRecipient);
    }

    function collect(
        address asset,
        uint256 amount
    ) external onlyRole(TREASURY_ROLE) {
        _collect(asset, amount, reserveRecipient);
    }

    function collectTo(
        address asset,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient();
        _collect(asset, amount, recipient);
    }

    function collectBatch(
        address[] calldata assets,
        uint256[] calldata amounts
    ) external onlyRole(TREASURY_ROLE) {
        uint256 length = assets.length;
        if (length == 0 || length > 32) revert InvalidArrayLength();
        if (length != amounts.length) revert ArrayLengthMismatch();
        address recipient = reserveRecipient;
        for (uint256 i; i < length; ++i) {
            _collect(assets[i], amounts[i], recipient);
        }
    }

    function recoverToken(
        address token,
        address recipient,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || recipient == address(0)) revert InvalidRecipient();
        token.safeTransfer(recipient, amount);
        emit TokenRecovered(token, recipient, amount);
    }

    function _collect(
        address asset,
        uint256 amount,
        address recipient
    ) internal {
        pool.claimReserves(asset, amount, recipient);
        emit MarketReservesCollected(asset, amount, recipient);
    }
}

