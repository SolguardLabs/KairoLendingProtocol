// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";
import { ITransferValidator } from "../interfaces/ITransferValidator.sol";

/// @title KairoSupplyToken
/// @notice ERC-20 receipt token representing transferable shares in a Kairo market.
/// @dev Only the pool may create, destroy, or move shares during liquidation.
contract KairoSupplyToken is IERC20 {
    string public override name;
    string public override symbol;
    uint8 public immutable override decimals;

    address public immutable pool;
    address public immutable underlyingAsset;

    uint256 public override totalSupply;

    mapping(address account => uint256 balance) private _balances;
    mapping(address owner => mapping(address spender => uint256 amount)) private _allowances;

    error OnlyPool(address caller);
    error ZeroAddress();
    error InvalidPool(address pool);
    error InvalidUnderlyingAsset(address asset);
    error InsufficientBalance(address account, uint256 available, uint256 required);
    error InsufficientAllowance(address spender, uint256 available, uint256 required);

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool(msg.sender);
        _;
    }

    constructor(
        address pool_,
        address underlyingAsset_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) {
        if (pool_ == address(0)) revert InvalidPool(pool_);
        if (underlyingAsset_ == address(0)) revert InvalidUnderlyingAsset(underlyingAsset_);
        pool = pool_;
        underlyingAsset = underlyingAsset_;
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function balanceOf(
        address account
    ) external view override returns (uint256) {
        return _balances[account];
    }

    function allowance(
        address owner,
        address spender
    ) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(
        address to,
        uint256 amount
    ) external override returns (bool) {
        _transfer(msg.sender, to, amount, true);
        return true;
    }

    function approve(
        address spender,
        uint256 amount
    ) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount, true);
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedAmount
    ) external returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedAmount);
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedAmount
    ) external returns (bool) {
        uint256 currentAllowance = _allowances[msg.sender][spender];
        if (currentAllowance < subtractedAmount) {
            revert InsufficientAllowance(spender, currentAllowance, subtractedAmount);
        }
        unchecked {
            _approve(msg.sender, spender, currentAllowance - subtractedAmount);
        }
        return true;
    }

    /// @notice Creates market shares after the pool receives underlying assets.
    function mint(
        address account,
        uint256 amount
    ) external onlyPool {
        if (account == address(0)) revert ZeroAddress();
        totalSupply += amount;
        unchecked {
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);
    }

    /// @notice Destroys market shares as the pool returns underlying assets.
    function burn(
        address account,
        uint256 amount
    ) external onlyPool {
        if (account == address(0)) revert ZeroAddress();
        uint256 balance = _balances[account];
        if (balance < amount) revert InsufficientBalance(account, balance, amount);
        unchecked {
            _balances[account] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    /// @notice Moves seized shares without applying the ordinary collateral transfer check.
    function transferOnLiquidation(
        address from,
        address to,
        uint256 amount
    ) external onlyPool {
        _transfer(from, to, amount, false);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount,
        bool validate
    ) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();

        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        uint256 toBalance = _balances[to];

        if (validate && from != to) {
            ITransferValidator(pool)
                .validateSupplyTokenTransfer(
                    underlyingAsset, from, to, amount, fromBalance, toBalance
                );
        }

        if (from != to) {
            unchecked {
                _balances[from] = fromBalance - amount;
                _balances[to] = toBalance + amount;
            }
        }
        emit Transfer(from, to, amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) private {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) private {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance == type(uint256).max) return;
        if (currentAllowance < amount) {
            revert InsufficientAllowance(spender, currentAllowance, amount);
        }
        unchecked {
            _allowances[owner][spender] = currentAllowance - amount;
        }
        emit Approval(owner, spender, currentAllowance - amount);
    }
}
