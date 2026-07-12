// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { KairoLendingPool } from "../KairoLendingPool.sol";
import { ProtocolAccess } from "../core/ProtocolAccess.sol";
import { DataTypes } from "../libraries/DataTypes.sol";

/// @title KairoConfigurator
/// @notice Operational facade for listing markets and applying reviewed parameter sets.
/// @dev This contract must hold the corresponding roles on the lending pool.
contract KairoConfigurator is ProtocolAccess {
    uint256 public constant MAX_BATCH_SIZE = 32;

    struct RiskProfile {
        uint16 loanToValueBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationBonusBps;
        uint16 closeFactorBps;
        bool exists;
    }

    struct MarketListing {
        address asset;
        string supplyTokenName;
        string supplyTokenSymbol;
        DataTypes.MarketConfig parameters;
    }

    struct MarketCaps {
        address asset;
        uint128 supplyCap;
        uint128 borrowCap;
    }

    struct MarketSources {
        address asset;
        address priceFeed;
        address rateModel;
        uint40 priceMaxAge;
    }

    struct MarketReserveFactor {
        address asset;
        uint16 reserveFactorBps;
    }

    KairoLendingPool public immutable pool;
    mapping(bytes32 profileId => RiskProfile profile) private _riskProfiles;
    bytes32[] private _profileIds;
    mapping(bytes32 profileId => uint256 indexPlusOne) private _profileIndex;

    error InvalidPool();
    error InvalidProfile(bytes32 profileId);
    error InvalidBatchLength(uint256 length);
    error ArrayLengthMismatch();

    event RiskProfileDefined(
        bytes32 indexed profileId,
        uint256 loanToValueBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        uint256 closeFactorBps
    );
    event RiskProfileRemoved(bytes32 indexed profileId);
    event RiskProfileApplied(bytes32 indexed profileId, address indexed asset);
    event MarketConfigured(address indexed asset, address indexed supplyToken);
    event RiskEngineInstalled(address indexed engine);
    event BatchCapsApplied(uint256 marketCount);
    event BatchSourcesApplied(uint256 marketCount);
    event BatchReserveFactorsApplied(uint256 marketCount);
    event BatchBorrowingApplied(uint256 marketCount, bool enabled);
    event BatchStatusApplied(uint256 marketCount, DataTypes.MarketStatus status);

    constructor(
        address initialAdmin,
        KairoLendingPool pool_
    ) ProtocolAccess(initialAdmin) {
        if (address(pool_) == address(0) || address(pool_).code.length == 0) revert InvalidPool();
        pool = pool_;
    }

    function installRiskEngine(
        address engine
    ) external onlyRole(CONFIGURATOR_ROLE) {
        pool.setRiskEngine(engine);
        emit RiskEngineInstalled(engine);
    }

    function listMarket(
        MarketListing calldata listing
    ) external onlyRole(CONFIGURATOR_ROLE) returns (address supplyToken) {
        supplyToken = _listMarket(listing);
    }

    function listMarkets(
        MarketListing[] calldata listings
    ) external onlyRole(CONFIGURATOR_ROLE) returns (address[] memory supplyTokens) {
        _validateBatchLength(listings.length);
        supplyTokens = new address[](listings.length);
        for (uint256 i; i < listings.length; ++i) {
            supplyTokens[i] = _listMarket(listings[i]);
        }
    }

    function defineRiskProfile(
        bytes32 profileId,
        RiskProfile calldata profile
    ) external onlyRole(CONFIGURATOR_ROLE) {
        if (profileId == bytes32(0) || !profile.exists) revert InvalidProfile(profileId);
        _validateRiskProfile(profile);

        if (_profileIndex[profileId] == 0) {
            _profileIds.push(profileId);
            _profileIndex[profileId] = _profileIds.length;
        }
        _riskProfiles[profileId] = profile;
        emit RiskProfileDefined(
            profileId,
            profile.loanToValueBps,
            profile.liquidationThresholdBps,
            profile.liquidationBonusBps,
            profile.closeFactorBps
        );
    }

    function removeRiskProfile(
        bytes32 profileId
    ) external onlyRole(CONFIGURATOR_ROLE) {
        if (!_riskProfiles[profileId].exists) revert InvalidProfile(profileId);
        delete _riskProfiles[profileId];

        uint256 index = _profileIndex[profileId] - 1;
        uint256 last = _profileIds.length - 1;
        if (index != last) {
            bytes32 moved = _profileIds[last];
            _profileIds[index] = moved;
            _profileIndex[moved] = index + 1;
        }
        _profileIds.pop();
        delete _profileIndex[profileId];
        emit RiskProfileRemoved(profileId);
    }

    function applyRiskProfile(
        address asset,
        bytes32 profileId
    ) public onlyRole(CONFIGURATOR_ROLE) {
        RiskProfile memory profile = _riskProfiles[profileId];
        if (!profile.exists) revert InvalidProfile(profileId);
        pool.setMarketRiskParameters(
            asset,
            profile.loanToValueBps,
            profile.liquidationThresholdBps,
            profile.liquidationBonusBps,
            profile.closeFactorBps
        );
        emit RiskProfileApplied(profileId, asset);
    }

    function applyRiskProfileBatch(
        address[] calldata assets,
        bytes32 profileId
    ) external onlyRole(CONFIGURATOR_ROLE) {
        _validateBatchLength(assets.length);
        RiskProfile memory profile = _riskProfiles[profileId];
        if (!profile.exists) revert InvalidProfile(profileId);

        for (uint256 i; i < assets.length; ++i) {
            pool.setMarketRiskParameters(
                assets[i],
                profile.loanToValueBps,
                profile.liquidationThresholdBps,
                profile.liquidationBonusBps,
                profile.closeFactorBps
            );
            emit RiskProfileApplied(profileId, assets[i]);
        }
    }

    function setMarketCaps(
        MarketCaps calldata caps
    ) external onlyRole(CONFIGURATOR_ROLE) {
        pool.setMarketCaps(caps.asset, caps.supplyCap, caps.borrowCap);
    }

    function setMarketCapsBatch(
        MarketCaps[] calldata updates
    ) external onlyRole(CONFIGURATOR_ROLE) {
        _validateBatchLength(updates.length);
        for (uint256 i; i < updates.length; ++i) {
            pool.setMarketCaps(updates[i].asset, updates[i].supplyCap, updates[i].borrowCap);
        }
        emit BatchCapsApplied(updates.length);
    }

    function setMarketSources(
        MarketSources calldata sources
    ) external onlyRole(CONFIGURATOR_ROLE) {
        _setMarketSources(sources);
    }

    function setMarketSourcesBatch(
        MarketSources[] calldata updates
    ) external onlyRole(CONFIGURATOR_ROLE) {
        _validateBatchLength(updates.length);
        for (uint256 i; i < updates.length; ++i) {
            _setMarketSources(updates[i]);
        }
        emit BatchSourcesApplied(updates.length);
    }

    function setReserveFactorsBatch(
        MarketReserveFactor[] calldata updates
    ) external onlyRole(CONFIGURATOR_ROLE) {
        _validateBatchLength(updates.length);
        for (uint256 i; i < updates.length; ++i) {
            pool.setReserveFactor(updates[i].asset, updates[i].reserveFactorBps);
        }
        emit BatchReserveFactorsApplied(updates.length);
    }

    function setBorrowingBatch(
        address[] calldata assets,
        bool enabled
    ) external onlyRole(CONFIGURATOR_ROLE) {
        _validateBatchLength(assets.length);
        for (uint256 i; i < assets.length; ++i) {
            pool.setBorrowingEnabled(assets[i], enabled);
        }
        emit BatchBorrowingApplied(assets.length, enabled);
    }

    function setMarketStatus(
        address asset,
        DataTypes.MarketStatus status
    ) external onlyRole(GUARDIAN_ROLE) {
        pool.setMarketStatus(asset, status);
    }

    function setMarketStatusBatch(
        address[] calldata assets,
        DataTypes.MarketStatus status
    ) external onlyRole(GUARDIAN_ROLE) {
        _validateBatchLength(assets.length);
        for (uint256 i; i < assets.length; ++i) {
            pool.setMarketStatus(assets[i], status);
        }
        emit BatchStatusApplied(assets.length, status);
    }

    function setProtocolPaused(
        bool paused
    ) external onlyRole(GUARDIAN_ROLE) {
        pool.setProtocolPaused(paused);
    }

    function riskProfile(
        bytes32 profileId
    ) external view returns (RiskProfile memory) {
        RiskProfile memory profile = _riskProfiles[profileId];
        if (!profile.exists) revert InvalidProfile(profileId);
        return profile;
    }

    function riskProfileCount() external view returns (uint256) {
        return _profileIds.length;
    }

    function riskProfileAt(
        uint256 index
    ) external view returns (bytes32 profileId, RiskProfile memory profile) {
        profileId = _profileIds[index];
        profile = _riskProfiles[profileId];
    }

    function _listMarket(
        MarketListing calldata listing
    ) internal returns (address supplyToken) {
        supplyToken = pool.listMarket(
            listing.asset, listing.supplyTokenName, listing.supplyTokenSymbol, listing.parameters
        );
        emit MarketConfigured(listing.asset, supplyToken);
    }

    function _setMarketSources(
        MarketSources calldata sources
    ) internal {
        pool.setMarketSources(
            sources.asset, sources.priceFeed, sources.rateModel, sources.priceMaxAge
        );
    }

    function _validateRiskProfile(
        RiskProfile calldata profile
    ) internal pure {
        if (
            profile.loanToValueBps > profile.liquidationThresholdBps
                || profile.liquidationThresholdBps > 10_000 || profile.liquidationBonusBps > 5000
                || profile.closeFactorBps == 0 || profile.closeFactorBps > 10_000
        ) revert InvalidProfile(bytes32(0));
    }

    function _validateBatchLength(
        uint256 length
    ) internal pure {
        if (length == 0 || length > MAX_BATCH_SIZE) revert InvalidBatchLength(length);
    }
}

