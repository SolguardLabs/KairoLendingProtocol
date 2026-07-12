// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title PercentageMath
/// @notice Basis-point arithmetic with explicit rounding modes.
library PercentageMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant HALF_BPS = 5000;

    error InvalidBasisPoints(uint256 bps);
    error PercentageOverflow();
    error DivisionByZero();

    function percentMul(
        uint256 value,
        uint256 bps
    ) internal pure returns (uint256) {
        _validate(bps);
        if (value == 0 || bps == 0) return 0;
        if (value > (type(uint256).max - HALF_BPS) / bps) revert PercentageOverflow();
        return (value * bps + HALF_BPS) / BPS;
    }

    function percentMulDown(
        uint256 value,
        uint256 bps
    ) internal pure returns (uint256) {
        _validate(bps);
        if (value == 0 || bps == 0) return 0;
        if (value > type(uint256).max / bps) revert PercentageOverflow();
        return value * bps / BPS;
    }

    function percentMulUp(
        uint256 value,
        uint256 bps
    ) internal pure returns (uint256) {
        _validate(bps);
        if (value == 0 || bps == 0) return 0;
        if (value > type(uint256).max / bps) revert PercentageOverflow();
        uint256 product = value * bps;
        return (product - 1) / BPS + 1;
    }

    function percentDiv(
        uint256 value,
        uint256 bps
    ) internal pure returns (uint256) {
        _validateDivisor(bps);
        uint256 halfBps = bps / 2;
        if (value > (type(uint256).max - halfBps) / BPS) revert PercentageOverflow();
        return (value * BPS + halfBps) / bps;
    }

    function complement(
        uint256 bps
    ) internal pure returns (uint256) {
        _validate(bps);
        return BPS - bps;
    }

    function _validate(
        uint256 bps
    ) private pure {
        if (bps > BPS) revert InvalidBasisPoints(bps);
    }

    function _validateDivisor(
        uint256 bps
    ) private pure {
        if (bps == 0) revert DivisionByZero();
        _validate(bps);
    }
}
