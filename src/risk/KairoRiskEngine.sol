// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IKairoPoolView } from "../interfaces/IKairoPoolView.sol";
import { IPriceFeed } from "../interfaces/IPriceFeed.sol";
import { DataTypes } from "../libraries/DataTypes.sol";
import { MarketMath } from "../libraries/MarketMath.sol";
import { IKairoRiskEngine } from "./IKairoRiskEngine.sol";

/// @title KairoRiskEngine
/// @notice Computes cross-market account solvency using fresh oracle observations.
contract KairoRiskEngine is IKairoRiskEngine {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint8 private constant MAX_SUPPORTED_DECIMALS = 36;

    IKairoPoolView public immutable pool;

    error InvalidPool();
    error InvalidAccount();
    error InvalidAmount();
    error MarketNotActive(address asset);
    error BorrowingDisabled(address asset);
    error BorrowCapExceeded(address asset, uint256 cap, uint256 requestedTotal);
    error InsufficientCollateral(uint256 borrowCapacity, uint256 debtAfter);
    error UnsafeCollateralReduction(uint256 thresholdValue, uint256 debtValue);
    error InsufficientSupply(address asset, uint256 balance, uint256 requested);
    error AccountNotLiquidatable(address account);
    error NoDebt(address asset, address account);
    error NoCollateral(address asset, address account);
    error InvalidPriceFeed(address asset);
    error InvalidPrice(address asset);
    error StalePrice(address asset, uint256 updatedAt, uint256 maxAge);
    error FuturePrice(address asset, uint256 updatedAt);
    error UnsupportedDecimals(address asset, uint256 decimals);
    error MathOverflow();

    struct PriceData {
        uint256 priceWad;
        uint256 assetUnit;
    }

    struct AccountTotals {
        uint256 collateralValue;
        uint256 debtValue;
        uint256 borrowCapacity;
        uint256 liquidationThresholdValue;
    }

    constructor(
        IKairoPoolView pool_
    ) {
        if (address(pool_) == address(0) || address(pool_).code.length == 0) {
            revert InvalidPool();
        }
        pool = pool_;
    }

    function getAccountLiquidity(
        address account
    ) public view returns (DataTypes.AccountLiquidity memory) {
        if (account == address(0)) revert InvalidAccount();
        return _accountLiquidity(account, address(0), 0, 0);
    }

    /// @notice Simulates one collateral reduction and one debt increase in the same asset.
    function getHypotheticalAccountLiquidity(
        address account,
        address changedAsset,
        uint256 collateralReduction,
        uint256 borrowIncrease
    ) public view returns (DataTypes.AccountLiquidity memory) {
        if (account == address(0)) revert InvalidAccount();
        if (changedAsset == address(0) && (collateralReduction != 0 || borrowIncrease != 0)) {
            revert MarketNotActive(changedAsset);
        }
        return _accountLiquidity(account, changedAsset, collateralReduction, borrowIncrease);
    }

    function validateBorrow(
        address account,
        address asset,
        uint256 amount
    ) external view {
        if (account == address(0)) revert InvalidAccount();
        if (amount == 0) revert InvalidAmount();

        DataTypes.MarketConfig memory config = pool.getMarketConfig(asset);
        if (config.status != DataTypes.MarketStatus.Active || !pool.isMarketActive(asset)) {
            revert MarketNotActive(asset);
        }
        if (!config.borrowingEnabled) revert BorrowingDisabled(asset);

        DataTypes.MarketState memory state = pool.getMarketState(asset);
        uint256 requestedTotal = uint256(state.totalBorrowAssets) + amount;
        if (config.borrowCap != 0 && requestedTotal > config.borrowCap) {
            revert BorrowCapExceeded(asset, config.borrowCap, requestedTotal);
        }

        DataTypes.AccountLiquidity memory liquidity = _accountLiquidity(account, asset, 0, amount);
        if (liquidity.debtValue > liquidity.borrowCapacity) {
            revert InsufficientCollateral(liquidity.borrowCapacity, liquidity.debtValue);
        }
    }

    function validateCollateralReduction(
        address account,
        address asset,
        uint256 assets
    ) external view {
        if (account == address(0)) revert InvalidAccount();
        if (assets == 0) return;

        uint256 supplied = pool.supplyBalance(asset, account);
        if (assets > supplied) revert InsufficientSupply(asset, supplied, assets);
        if (!_hasDebt(account)) return;

        DataTypes.AccountLiquidity memory liquidity = _accountLiquidity(account, asset, assets, 0);
        if (liquidity.debtValue > liquidity.liquidationThresholdValue) {
            revert UnsafeCollateralReduction(
                liquidity.liquidationThresholdValue, liquidity.debtValue
            );
        }
    }

    function isLiquidatable(
        address account
    ) public view returns (bool) {
        DataTypes.AccountLiquidity memory liquidity = getAccountLiquidity(account);
        return liquidity.debtValue != 0 && liquidity.debtValue > liquidity.liquidationThresholdValue;
    }

    /// @notice Quotes a close-factor-limited liquidation and caps repayment to available collateral.
    function liquidationQuote(
        address account,
        address collateralAsset,
        address debtAsset,
        uint256 requestedRepay
    ) external view returns (uint256 repayAssets, uint256 seizeCollateralAssets) {
        if (account == address(0)) revert InvalidAccount();
        if (requestedRepay == 0) revert InvalidAmount();
        if (!isLiquidatable(account)) revert AccountNotLiquidatable(account);

        DataTypes.MarketConfig memory debtConfig = pool.getMarketConfig(debtAsset);
        DataTypes.MarketConfig memory collateralConfig = pool.getMarketConfig(collateralAsset);
        if (debtConfig.status == DataTypes.MarketStatus.Unlisted) {
            revert MarketNotActive(debtAsset);
        }
        if (collateralConfig.status == DataTypes.MarketStatus.Unlisted) {
            revert MarketNotActive(collateralAsset);
        }

        uint256 debtBalance = pool.borrowBalance(debtAsset, account);
        if (debtBalance == 0) revert NoDebt(debtAsset, account);
        uint256 collateralBalance = pool.supplyBalance(collateralAsset, account);
        if (collateralBalance == 0) revert NoCollateral(collateralAsset, account);

        uint256 closeLimit = _mulDivDown(debtBalance, debtConfig.closeFactorBps, BPS);
        if (closeLimit == 0) revert InvalidAmount();
        repayAssets = _min(requestedRepay, _min(debtBalance, closeLimit));

        PriceData memory debtPrice = _readPrice(debtAsset, debtConfig);
        PriceData memory collateralPrice = _readPrice(collateralAsset, collateralConfig);
        uint256 repayValue = _assetsToUsdUp(repayAssets, debtPrice);
        uint256 seizeValue =
            _mulDivUp(repayValue, BPS + uint256(collateralConfig.liquidationBonusBps), BPS);
        seizeCollateralAssets = _usdToAssetsUp(seizeValue, collateralPrice);

        if (seizeCollateralAssets > collateralBalance) {
            seizeCollateralAssets = collateralBalance;
            uint256 collateralValue = _assetsToUsdDown(collateralBalance, collateralPrice);
            uint256 repayValueCovered = _mulDivDown(
                collateralValue, BPS, BPS + uint256(collateralConfig.liquidationBonusBps)
            );
            uint256 collateralLimitedRepay = _usdToAssetsDown(repayValueCovered, debtPrice);
            repayAssets = _min(repayAssets, collateralLimitedRepay);
            if (repayAssets == 0) revert InvalidAmount();

            // Recompute seizure from the adjusted repay to avoid charging surplus collateral.
            repayValue = _assetsToUsdUp(repayAssets, debtPrice);
            seizeValue =
                _mulDivUp(repayValue, BPS + uint256(collateralConfig.liquidationBonusBps), BPS);
            seizeCollateralAssets =
                _min(collateralBalance, _usdToAssetsUp(seizeValue, collateralPrice));
        }
    }

    function _accountLiquidity(
        address account,
        address changedAsset,
        uint256 collateralReduction,
        uint256 borrowIncrease
    ) internal view returns (DataTypes.AccountLiquidity memory) {
        AccountTotals memory totals;
        uint256 count = pool.marketCount();
        bool changedAssetSeen = changedAsset == address(0);

        for (uint256 i; i < count; ++i) {
            address asset = pool.marketAt(i);
            DataTypes.MarketConfig memory config = pool.getMarketConfig(asset);
            uint256 supplied = pool.supplyBalance(asset, account);
            uint256 borrowed = pool.borrowBalance(asset, account);

            if (asset == changedAsset) {
                changedAssetSeen = true;
                if (collateralReduction > supplied) {
                    revert InsufficientSupply(asset, supplied, collateralReduction);
                }
                supplied -= collateralReduction;
                borrowed += borrowIncrease;
            }

            if (supplied == 0 && borrowed == 0) continue;
            PriceData memory price = _readPrice(asset, config);

            if (supplied != 0 && config.liquidationThresholdBps != 0) {
                uint256 collateralValue = _assetsToUsdDown(supplied, price);
                totals.collateralValue += collateralValue;
                totals.borrowCapacity += _mulDivDown(collateralValue, config.loanToValueBps, BPS);
                totals.liquidationThresholdValue += _mulDivDown(
                    collateralValue, config.liquidationThresholdBps, BPS
                );
            }
            if (borrowed != 0) {
                totals.debtValue += _assetsToUsdUp(borrowed, price);
            }
        }

        if (!changedAssetSeen) revert MarketNotActive(changedAsset);
        return MarketMath.accountLiquidity(
            totals.collateralValue,
            totals.debtValue,
            totals.borrowCapacity,
            totals.liquidationThresholdValue
        );
    }

    function _readPrice(
        address asset,
        DataTypes.MarketConfig memory config
    ) internal view returns (PriceData memory data) {
        if (config.priceFeed == address(0) || config.priceFeed.code.length == 0) {
            revert InvalidPriceFeed(asset);
        }
        if (config.assetDecimals > MAX_SUPPORTED_DECIMALS) {
            revert UnsupportedDecimals(asset, config.assetDecimals);
        }

        uint8 feedDecimals;
        try IPriceFeed(config.priceFeed).decimals() returns (uint8 value) {
            feedDecimals = value;
        } catch {
            revert InvalidPriceFeed(asset);
        }
        if (feedDecimals > MAX_SUPPORTED_DECIMALS) {
            revert UnsupportedDecimals(asset, feedDecimals);
        }

        uint256 price;
        uint256 updatedAt;
        try IPriceFeed(config.priceFeed).latestPrice() returns (uint256 value, uint256 timestamp) {
            price = value;
            updatedAt = timestamp;
        } catch {
            revert InvalidPrice(asset);
        }

        uint256 currentTime = block.timestamp;
        if (price == 0 || updatedAt == 0) revert InvalidPrice(asset);
        if (updatedAt > currentTime) revert FuturePrice(asset, updatedAt);
        if (config.priceMaxAge == 0 || currentTime - updatedAt > config.priceMaxAge) {
            revert StalePrice(asset, updatedAt, config.priceMaxAge);
        }

        data.priceWad = _normalizePrice(price, feedDecimals, asset);
        data.assetUnit = 10 ** uint256(config.assetDecimals);
    }

    function _normalizePrice(
        uint256 price,
        uint8 feedDecimals,
        address asset
    ) internal pure returns (uint256) {
        if (feedDecimals == 18) return price;
        if (feedDecimals < 18) {
            uint256 factor = 10 ** uint256(18 - feedDecimals);
            if (price > type(uint256).max / factor) revert MathOverflow();
            return price * factor;
        }
        uint256 normalized = price / (10 ** uint256(feedDecimals - 18));
        if (normalized == 0) revert InvalidPrice(asset);
        return normalized;
    }

    function _hasDebt(
        address account
    ) internal view returns (bool) {
        uint256 count = pool.marketCount();
        for (uint256 i; i < count; ++i) {
            if (pool.borrowBalance(pool.marketAt(i), account) != 0) return true;
        }
        return false;
    }

    function _assetsToUsdDown(
        uint256 assets,
        PriceData memory data
    ) internal pure returns (uint256) {
        return _mulDivDown(assets, data.priceWad, data.assetUnit);
    }

    function _assetsToUsdUp(
        uint256 assets,
        PriceData memory data
    ) internal pure returns (uint256) {
        return _mulDivUp(assets, data.priceWad, data.assetUnit);
    }

    function _usdToAssetsDown(
        uint256 valueWad,
        PriceData memory data
    ) internal pure returns (uint256) {
        return _mulDivDown(valueWad, data.assetUnit, data.priceWad);
    }

    function _usdToAssetsUp(
        uint256 valueWad,
        PriceData memory data
    ) internal pure returns (uint256) {
        return _mulDivUp(valueWad, data.assetUnit, data.priceWad);
    }

    function _mulDivDown(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        if (denominator == 0) revert MathOverflow();
        unchecked {
            uint256 low;
            uint256 high;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                low := mul(x, y)
                high := sub(sub(mm, low), lt(mm, low))
            }
            if (high == 0) return low / denominator;
            if (denominator <= high) revert MathOverflow();

            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, denominator)
                high := sub(high, gt(remainder, low))
                low := sub(low, remainder)
            }
            uint256 powerOfTwo = denominator & (0 - denominator);
            assembly ("memory-safe") {
                denominator := div(denominator, powerOfTwo)
                low := div(low, powerOfTwo)
                powerOfTwo := add(div(sub(0, powerOfTwo), powerOfTwo), 1)
            }
            low |= high * powerOfTwo;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            return low * inverse;
        }
    }

    function _mulDivUp(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = _mulDivDown(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) {
            if (result == type(uint256).max) revert MathOverflow();
            unchecked {
                ++result;
            }
        }
    }

    function _min(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
