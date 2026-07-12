// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @title SafeTransferLib
/// @notice Handles ERC-20 implementations that omit or inconsistently encode return values.
library SafeTransferLib {
    error TokenHasNoCode(address token);
    error TransferFailed(address token);
    error TransferFromFailed(address token);
    error ApprovalFailed(address token);
    error BalanceQueryFailed(address token);
    error NativeTransferFailed(address recipient);

    function safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        _requireCode(token);
        if (!_callOptionalReturn(token, abi.encodeCall(IERC20.transfer, (to, amount)))) {
            revert TransferFailed(token);
        }
    }

    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        _requireCode(token);
        if (!_callOptionalReturn(token, abi.encodeCall(IERC20.transferFrom, (from, to, amount)))) {
            revert TransferFromFailed(token);
        }
    }

    function safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        _requireCode(token);
        if (!_callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, amount)))) {
            revert ApprovalFailed(token);
        }
    }

    /// @notice Sets allowance for tokens that require resetting it to zero first.
    function forceApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        _requireCode(token);
        if (_callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, amount)))) return;
        if (!_callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, 0)))) {
            revert ApprovalFailed(token);
        }
        if (!_callOptionalReturn(token, abi.encodeCall(IERC20.approve, (spender, amount)))) {
            revert ApprovalFailed(token);
        }
    }

    function safeBalanceOf(
        address token,
        address account
    ) internal view returns (uint256 balance) {
        _requireCode(token);
        (bool success, bytes memory result) =
            token.staticcall(abi.encodeCall(IERC20.balanceOf, (account)));
        if (!success || result.length < 32) revert BalanceQueryFailed(token);
        balance = abi.decode(result, (uint256));
    }

    function safeTransferNative(
        address to,
        uint256 amount
    ) internal {
        (bool success,) = to.call{ value: amount }("");
        if (!success) revert NativeTransferFailed(to);
    }

    function _requireCode(
        address token
    ) private view {
        if (token.code.length == 0) revert TokenHasNoCode(token);
    }

    function _callOptionalReturn(
        address token,
        bytes memory data
    ) private returns (bool) {
        (bool success, bytes memory result) = token.call(data);
        if (!success) return false;
        if (result.length == 0) return true;
        if (result.length < 32) return false;
        return abi.decode(result, (bool));
    }
}
