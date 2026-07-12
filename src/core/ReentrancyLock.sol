// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ReentrancyLock
/// @notice Shared single-slot lock for state-changing protocol entry points.
abstract contract ReentrancyLock {
    uint256 private constant _UNLOCKED = 1;
    uint256 private constant _LOCKED = 2;

    uint256 private _lockState = _UNLOCKED;

    error ReentrantCall();

    modifier nonReentrant() {
        if (_lockState == _LOCKED) revert ReentrantCall();
        _lockState = _LOCKED;
        _;
        _lockState = _UNLOCKED;
    }
}

