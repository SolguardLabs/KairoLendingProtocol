// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IKairoPoolView } from "../interfaces/IKairoPoolView.sol";
import { IPriceFeed } from "../interfaces/IPriceFeed.sol";
import { IRateModel } from "../interfaces/IRateModel.sol";
import { DataTypes } from "../libraries/DataTypes.sol";
import { MarketMath } from "../libraries/MarketMath.sol";

/// @title KairoProtocolLens
/// @notice Batched, presentation-oriented views over Kairo markets and accounts.
contract KairoProtocolLens {
    uint256 public constant RAY = 1e27;
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    IKairoPoolView public immutable pool;

    error InvalidPool();
    error InvalidPagination();
    error RateOverflow();

    struct OracleView {
        uint256 priceWad;
        uint256 updatedAt;
        uint8 sourceDecimals;
        bool valid;
        bool stale;
    }

    struct RateView {
        uint256 utilizationRay;
        uint256 borrowRatePerSecondRay;
        uint256 supplyRatePerSecondRay;
        uint256 borrowAprRay;
        uint256 supplyAprRay;
        bool valid;
    }

    struct MarketView {
        address asset;
        DataTypes.MarketConfig config;
        DataTypes.MarketState state;
        uint256 cash;
        uint256 availableLiquidity;
        uint256 totalSupplyShares;
        uint256 exchangeRateRay;
        uint256 previewBorrowIndex;
        OracleView oracle;
        RateView rates;
        bool active;
    }

    struct PositionView {
        address asset;
        uint256 suppliedAssets;
        uint256 supplyShares;
        uint256 currentDebt;
        uint256 principal;
        uint256 accruedInterest;
        uint256 positionInterestIndex;
        uint256 currentBorrowIndex;
        uint256 collateralValueUsd;
        uint256 borrowCapacityUsd;
        uint256 liquidationThresholdUsd;
        uint256 debtValueUsd;
        bool oracleValid;
    }

    struct AccountView {
        address account;
        DataTypes.AccountLiquidity liquidity;
        PositionView[] positions;
    }

    constructor(
        IKairoPoolView pool_
    ) {
        if (address(pool_) == address(0) || address(pool_).code.length == 0) {
            revert InvalidPool();
        }
        pool = pool_;
    }

    function marketCount() external view returns (uint256) {
        return pool.marketCount();
    }

    function getMarket(
        address asset
    ) public view returns (MarketView memory) {
        return _market(asset);
    }

    function getMarkets(
        uint256 offset,
        uint256 limit
    ) external view returns (MarketView[] memory markets) {
        uint256 count = pool.marketCount();
        (uint256 start, uint256 end) = _page(offset, limit, count);
        markets = new MarketView[](end - start);
        for (uint256 i = start; i < end; ++i) {
            markets[i - start] = _market(pool.marketAt(i));
        }
    }

    function getPosition(
        address account,
        address asset
    ) public view returns (PositionView memory) {
        DataTypes.MarketConfig memory config = pool.getMarketConfig(asset);
        DataTypes.DebtPosition memory debt = pool.getDebtPosition(asset, account);
        uint256 supplied = pool.supplyBalance(asset, account);
        uint256 currentDebt = pool.borrowBalance(asset, account);
        uint256 currentIndex = pool.previewBorrowIndex(asset);
        uint256 shares = _tokenBalance(config.supplyToken, account);
        OracleView memory oracle = _oracle(config);

        PositionView memory position;
        position.asset = asset;
        position.suppliedAssets = supplied;
        position.supplyShares = shares;
        position.currentDebt = currentDebt;
        position.principal = debt.principal;
        position.accruedInterest = currentDebt > debt.principal ? currentDebt - debt.principal : 0;
        position.positionInterestIndex = debt.interestIndex;
        position.currentBorrowIndex = currentIndex;
        position.oracleValid = oracle.valid;

        if (oracle.valid) {
            position.collateralValueUsd =
                _valueInUsd(supplied, oracle.priceWad, config.assetDecimals);
            position.borrowCapacityUsd =
                position.collateralValueUsd * config.loanToValueBps / 10_000;
            position.liquidationThresholdUsd =
                position.collateralValueUsd * config.liquidationThresholdBps / 10_000;
            position.debtValueUsd = _valueInUsd(currentDebt, oracle.priceWad, config.assetDecimals);
        }
        return position;
    }

    function getAccount(
        address account
    ) external view returns (AccountView memory result) {
        uint256 count = pool.marketCount();
        result.account = account;
        result.liquidity = pool.getAccountLiquidity(account);
        result.positions = new PositionView[](count);
        for (uint256 i; i < count; ++i) {
            result.positions[i] = getPosition(account, pool.marketAt(i));
        }
    }

    function getAccountPositions(
        address account,
        uint256 offset,
        uint256 limit
    ) external view returns (PositionView[] memory positions) {
        uint256 count = pool.marketCount();
        (uint256 start, uint256 end) = _page(offset, limit, count);
        positions = new PositionView[](end - start);
        for (uint256 i = start; i < end; ++i) {
            positions[i - start] = getPosition(account, pool.marketAt(i));
        }
    }

    function previewBorrowBalance(
        address asset,
        address account
    ) external view returns (uint256 debt, uint256 accruedInterest, uint256 currentIndex) {
        DataTypes.DebtPosition memory position = pool.getDebtPosition(asset, account);
        debt = pool.borrowBalance(asset, account);
        accruedInterest = debt > position.principal ? debt - position.principal : 0;
        currentIndex = pool.previewBorrowIndex(asset);
    }

    function previewSupplyBalance(
        address asset,
        address account
    ) external view returns (uint256 assets, uint256 shares, uint256 exchangeRateRay) {
        DataTypes.MarketConfig memory config = pool.getMarketConfig(asset);
        DataTypes.MarketState memory state = pool.getMarketState(asset);
        assets = pool.supplyBalance(asset, account);
        shares = _tokenBalance(config.supplyToken, account);
        uint256 totalShares = _tokenTotalSupply(config.supplyToken);
        exchangeRateRay = MarketMath.exchangeRate(state.totalSupplyAssets, totalShares);
    }

    function previewRates(
        address asset
    ) external view returns (RateView memory) {
        DataTypes.MarketConfig memory config = pool.getMarketConfig(asset);
        DataTypes.MarketState memory state = pool.getMarketState(asset);
        uint256 cash = _tokenBalance(asset, address(pool));
        return _rates(config, state, cash);
    }

    function _market(
        address asset
    ) internal view returns (MarketView memory market) {
        market.asset = asset;
        market.config = pool.getMarketConfig(asset);
        market.state = pool.getMarketState(asset);
        market.cash = _tokenBalance(asset, address(pool));
        market.availableLiquidity =
            MarketMath.availableLiquidity(market.cash, market.state.totalReserves);
        market.totalSupplyShares = _tokenTotalSupply(market.config.supplyToken);
        market.exchangeRateRay =
            MarketMath.exchangeRate(market.state.totalSupplyAssets, market.totalSupplyShares);
        market.previewBorrowIndex = pool.previewBorrowIndex(asset);
        market.oracle = _oracle(market.config);
        market.rates = _rates(market.config, market.state, market.cash);
        market.active = pool.isMarketActive(asset);
    }

    function _rates(
        DataTypes.MarketConfig memory config,
        DataTypes.MarketState memory state,
        uint256 cash
    ) internal view returns (RateView memory rates) {
        rates.utilizationRay =
            MarketMath.utilizationRate(cash, state.totalBorrowAssets, state.totalReserves);
        if (config.rateModel == address(0) || config.rateModel.code.length == 0) return rates;

        try IRateModel(config.rateModel)
            .getBorrowRate(cash, state.totalBorrowAssets, state.totalReserves) returns (
            uint256 rate
        ) {
            rates.borrowRatePerSecondRay = rate;
        } catch {
            return rates;
        }
        try IRateModel(config.rateModel)
            .getSupplyRate(
                cash, state.totalBorrowAssets, state.totalReserves, config.reserveFactorBps
            ) returns (
            uint256 rate
        ) {
            rates.supplyRatePerSecondRay = rate;
        } catch {
            return rates;
        }

        rates.borrowAprRay = _annualize(rates.borrowRatePerSecondRay);
        rates.supplyAprRay = _annualize(rates.supplyRatePerSecondRay);
        rates.valid = true;
    }

    function _oracle(
        DataTypes.MarketConfig memory config
    ) internal view returns (OracleView memory answer) {
        if (config.priceFeed == address(0) || config.priceFeed.code.length == 0) return answer;
        try IPriceFeed(config.priceFeed).decimals() returns (uint8 value) {
            answer.sourceDecimals = value;
        } catch {
            return answer;
        }
        if (answer.sourceDecimals > 36) return answer;

        uint256 rawPrice;
        try IPriceFeed(config.priceFeed).latestPrice() returns (uint256 price, uint256 timestamp) {
            rawPrice = price;
            answer.updatedAt = timestamp;
        } catch {
            return answer;
        }
        uint256 currentTime = block.timestamp;
        if (rawPrice == 0 || answer.updatedAt == 0 || answer.updatedAt > currentTime) {
            return answer;
        }

        answer.stale =
            config.priceMaxAge == 0 || currentTime - answer.updatedAt > config.priceMaxAge;
        answer.priceWad = _normalizePrice(rawPrice, answer.sourceDecimals);
        answer.valid = answer.priceWad != 0 && !answer.stale;
    }

    function _normalizePrice(
        uint256 price,
        uint8 sourceDecimals
    ) internal pure returns (uint256) {
        if (sourceDecimals == 18) return price;
        if (sourceDecimals > 18) return price / (10 ** uint256(sourceDecimals - 18));
        uint256 factor = 10 ** uint256(18 - sourceDecimals);
        return price <= type(uint256).max / factor ? price * factor : 0;
    }

    function _valueInUsd(
        uint256 assets,
        uint256 priceWad,
        uint8 assetDecimals
    ) internal pure returns (uint256) {
        if (assetDecimals > 36 || assets == 0 || priceWad == 0) return 0;
        uint256 unit = 10 ** uint256(assetDecimals);
        uint256 whole = assets / unit;
        uint256 remainder = assets % unit;
        if (whole > type(uint256).max / priceWad) return 0;
        uint256 head = whole * priceWad;
        if (remainder != 0 && priceWad > type(uint256).max / remainder) return 0;
        uint256 tail = remainder * priceWad / unit;
        return head <= type(uint256).max - tail ? head + tail : 0;
    }

    function _annualize(
        uint256 perSecondRateRay
    ) internal pure returns (uint256) {
        if (perSecondRateRay > type(uint256).max / SECONDS_PER_YEAR) revert RateOverflow();
        return perSecondRateRay * SECONDS_PER_YEAR;
    }

    function _tokenBalance(
        address token,
        address account
    ) internal view returns (uint256 balance) {
        if (token == address(0) || token.code.length == 0) return 0;
        try IERC20(token).balanceOf(account) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    function _tokenTotalSupply(
        address token
    ) internal view returns (uint256 supply) {
        if (token == address(0) || token.code.length == 0) return 0;
        try IERC20(token).totalSupply() returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    function _page(
        uint256 offset,
        uint256 limit,
        uint256 count
    ) internal pure returns (uint256 start, uint256 end) {
        if (limit == 0 || offset > count) revert InvalidPagination();
        start = offset;
        uint256 remaining = count - offset;
        end = offset + (limit < remaining ? limit : remaining);
    }
}
