// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title WadRayMath
/// @notice Fixed-point arithmetic for wad (1e18) and ray (1e27) values.
library WadRayMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 5e17;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 5e26;
    uint256 internal constant WAD_RAY_RATIO = 1e9;

    error MathOverflow();
    error DivisionByZero();

    function wadMul(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return _mulHalfUp(a, b, WAD, HALF_WAD);
    }

    function wadMulDown(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return _mulDown(a, b, WAD);
    }

    function wadDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return _divHalfUp(a, b, WAD);
    }

    function wadDivDown(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return _divDown(a, b, WAD);
    }

    function rayMul(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return _mulHalfUp(a, b, RAY, HALF_RAY);
    }

    function rayMulDown(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return _mulDown(a, b, RAY);
    }

    function rayDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return _divHalfUp(a, b, RAY);
    }

    function rayDivDown(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return _divDown(a, b, RAY);
    }

    function wadToRay(
        uint256 value
    ) internal pure returns (uint256 result) {
        if (value > type(uint256).max / WAD_RAY_RATIO) revert MathOverflow();
        return value * WAD_RAY_RATIO;
    }

    function rayToWad(
        uint256 value
    ) internal pure returns (uint256 result) {
        uint256 halfRatio = WAD_RAY_RATIO / 2;
        if (value > type(uint256).max - halfRatio) revert MathOverflow();
        return (value + halfRatio) / WAD_RAY_RATIO;
    }

    /// @notice Raises a ray-scaled base to an integer exponent.
    function rayPow(
        uint256 base,
        uint256 exponent
    ) internal pure returns (uint256 result) {
        result = (exponent & 1) == 0 ? RAY : base;
        for (exponent >>= 1; exponent != 0; exponent >>= 1) {
            base = rayMul(base, base);
            if ((exponent & 1) != 0) result = rayMul(result, base);
        }
    }

    function _mulHalfUp(
        uint256 a,
        uint256 b,
        uint256 scale,
        uint256 halfScale
    ) private pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        if (a > (type(uint256).max - halfScale) / b) revert MathOverflow();
        return (a * b + halfScale) / scale;
    }

    function _mulDown(
        uint256 a,
        uint256 b,
        uint256 scale
    ) private pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        if (a > type(uint256).max / b) revert MathOverflow();
        return a * b / scale;
    }

    function _divHalfUp(
        uint256 a,
        uint256 b,
        uint256 scale
    ) private pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        uint256 halfB = b / 2;
        if (a > (type(uint256).max - halfB) / scale) revert MathOverflow();
        return (a * scale + halfB) / b;
    }

    function _divDown(
        uint256 a,
        uint256 b,
        uint256 scale
    ) private pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        if (a > type(uint256).max / scale) revert MathOverflow();
        return a * scale / b;
    }
}
