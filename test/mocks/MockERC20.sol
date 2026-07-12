// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "../../src/interfaces/IERC20.sol";

/// @title MockERC20
/// @notice Configurable ERC-20 used by the Kairo test suite.
contract MockERC20 is IERC20 {
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);
    error ERC20InsufficientBalance(address account, uint256 balance, uint256 required);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 required);

    string public override name;
    string public override symbol;
    uint8 public immutable override decimals;

    uint256 public override totalSupply;

    mapping(address account => uint256 balance) public override balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public override allowance;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    /// @inheritdoc IERC20
    function transfer(
        address to,
        uint256 amount
    ) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc IERC20
    function approve(
        address spender,
        uint256 amount
    ) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Increases the allowance granted by the caller.
    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) external returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
        return true;
    }

    /// @notice Decreases the allowance granted by the caller.
    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) external returns (bool) {
        uint256 currentAllowance = allowance[msg.sender][spender];
        if (currentAllowance < subtractedValue) {
            revert ERC20InsufficientAllowance(spender, currentAllowance, subtractedValue);
        }

        unchecked {
            _approve(msg.sender, spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    /// @notice Creates `amount` tokens for `to`.
    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    /// @notice Destroys `amount` tokens owned by the caller.
    function burn(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
    }

    /// @notice Destroys `amount` tokens owned by `from`.
    /// @dev Permissionless by design so tests can prepare arbitrary state.
    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));

        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) {
            revert ERC20InsufficientBalance(from, fromBalance, amount);
        }

        unchecked {
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function _mint(
        address to,
        uint256 amount
    ) internal {
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));

        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(
        address from,
        uint256 amount
    ) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));

        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) {
            revert ERC20InsufficientBalance(from, fromBalance, amount);
        }

        unchecked {
            balanceOf[from] = fromBalance - amount;
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));

        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = allowance[owner][spender];
        if (currentAllowance == type(uint256).max) return;
        if (currentAllowance < amount) {
            revert ERC20InsufficientAllowance(spender, currentAllowance, amount);
        }

        unchecked {
            allowance[owner][spender] = currentAllowance - amount;
        }
        emit Approval(owner, spender, currentAllowance - amount);
    }
}
