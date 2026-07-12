// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { DataTypes } from "./DataTypes.sol";
import { WadRayMath } from "./WadRayMath.sol";

/// @title DebtMath
/// @notice Index-based borrower debt calculations.
library DebtMath {
    using WadRayMath for uint256;

    uint256 internal constant RAY = 1e27;

    error InvalidInterestIndex(uint256 index);
    error DecreasingInterestIndex(uint256 previousIndex, uint256 currentIndex);
    error DebtValueOverflow(uint256 value);
    error TimestampOverflow(uint256 timestamp);

    function currentDebt(
        DataTypes.DebtPosition memory position,
        uint256 currentIndex
    ) internal pure returns (uint256) {
        return debtAtIndex(position.principal, position.interestIndex, currentIndex);
    }

    function debtAtIndex(
        uint256 principal,
        uint256 positionIndex,
        uint256 currentIndex
    ) internal pure returns (uint256) {
        if (principal == 0) return 0;
        _validateIndices(positionIndex, currentIndex);
        return principal.rayMul(currentIndex.rayDiv(positionIndex));
    }

    function accruedInterest(
        uint256 principal,
        uint256 positionIndex,
        uint256 currentIndex
    ) internal pure returns (uint256) {
        uint256 debt = debtAtIndex(principal, positionIndex, currentIndex);
        return debt > principal ? debt - principal : 0;
    }

    function scaledDebt(
        uint256 debt,
        uint256 currentIndex
    ) internal pure returns (uint256) {
        if (currentIndex == 0) revert InvalidInterestIndex(currentIndex);
        return debt.rayDiv(currentIndex);
    }

    function debtFromScaled(
        uint256 scaledAmount,
        uint256 currentIndex
    ) internal pure returns (uint256) {
        if (currentIndex == 0) revert InvalidInterestIndex(currentIndex);
        return scaledAmount.rayMul(currentIndex);
    }

    /// @notice Linear per-second interest factor in ray precision.
    function linearInterestFactor(
        uint256 ratePerSecondRay,
        uint256 elapsed
    ) internal pure returns (uint256) {
        if (ratePerSecondRay != 0 && elapsed > (type(uint256).max - RAY) / ratePerSecondRay) {
            revert DebtValueOverflow(type(uint256).max);
        }
        return RAY + ratePerSecondRay * elapsed;
    }

    function nextBorrowIndex(
        uint256 currentIndex,
        uint256 ratePerSecondRay,
        uint256 elapsed
    ) internal pure returns (uint256) {
        if (currentIndex == 0) revert InvalidInterestIndex(currentIndex);
        if (elapsed == 0 || ratePerSecondRay == 0) return currentIndex;
        return currentIndex.rayMul(linearInterestFactor(ratePerSecondRay, elapsed));
    }

    function remainingDebt(
        uint256 debt,
        uint256 repayment
    ) internal pure returns (uint256) {
        return repayment >= debt ? 0 : debt - repayment;
    }

    /// @notice Materializes a position at `currentIndex` after applying a repayment.
    function checkpointAfterRepayment(
        DataTypes.DebtPosition memory position,
        uint256 currentIndex,
        uint256 repayment,
        uint256 timestamp
    ) internal pure returns (DataTypes.DebtPosition memory updated, uint256 repaid) {
        uint256 debt = currentDebt(position, currentIndex);
        repaid = repayment > debt ? debt : repayment;
        uint256 remaining = debt - repaid;
        updated = DataTypes.DebtPosition({
            principal: _toUint128(remaining),
            interestIndex: _toUint128(currentIndex),
            lastUpdate: _toUint40(timestamp)
        });
    }

    function _validateIndices(
        uint256 previousIndex,
        uint256 currentIndex
    ) private pure {
        if (previousIndex == 0 || currentIndex == 0) revert InvalidInterestIndex(0);
        if (currentIndex < previousIndex) {
            revert DecreasingInterestIndex(previousIndex, currentIndex);
        }
    }

    function _toUint128(
        uint256 value
    ) private pure returns (uint128) {
        if (value > type(uint128).max) revert DebtValueOverflow(value);
        // Bounds check above guarantees a lossless conversion.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    function _toUint40(
        uint256 value
    ) private pure returns (uint40) {
        if (value > type(uint40).max) revert TimestampOverflow(value);
        // Bounds check above guarantees a lossless conversion.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(value);
    }
}
