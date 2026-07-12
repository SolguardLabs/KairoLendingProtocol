// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ProtocolAccess } from "./core/ProtocolAccess.sol";
import { ReentrancyLock } from "./core/ReentrancyLock.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IKairoPoolView } from "./interfaces/IKairoPoolView.sol";
import { IRateModel } from "./interfaces/IRateModel.sol";
import { ITransferValidator } from "./interfaces/ITransferValidator.sol";
import { DataTypes } from "./libraries/DataTypes.sol";
import { DebtMath } from "./libraries/DebtMath.sol";
import { MarketMath } from "./libraries/MarketMath.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { WadRayMath } from "./libraries/WadRayMath.sol";
import { IKairoRiskEngine } from "./risk/IKairoRiskEngine.sol";
import { KairoSupplyToken } from "./tokens/KairoSupplyToken.sol";

/// @title KairoLendingPool
/// @notice Custody and accounting layer for Kairo's isolated asset markets.
contract KairoLendingPool is ProtocolAccess, ReentrancyLock, IKairoPoolView, ITransferValidator {
    using SafeTransferLib for address;
    using WadRayMath for uint256;

    uint256 public constant RAY = 1e27;
    uint256 public constant BPS = 10_000;

    mapping(address asset => DataTypes.MarketConfig config) private _marketConfigs;
    mapping(address asset => DataTypes.MarketState state) private _marketStates;
    mapping(address asset => mapping(address account => DataTypes.DebtPosition position)) private
        _debtPositions;
    address[] private _marketList;

    IKairoRiskEngine public riskEngine;
    address public treasury;
    bool public protocolPaused;

    error ZeroAddress();
    error InvalidAmount();
    error InvalidMarketAsset(address asset);
    error MarketAlreadyListed(address asset);
    error MarketNotListed(address asset);
    error MarketNotActive(address asset);
    error BorrowingDisabled(address asset);
    error ProtocolIsPaused();
    error InvalidMarketConfiguration();
    error SupplyCapExceeded(address asset, uint256 cap, uint256 requestedTotal);
    error BorrowCapExceeded(address asset, uint256 cap, uint256 requestedTotal);
    error InsufficientLiquidity(address asset, uint256 available, uint256 requested);
    error InsufficientShares(address account, uint256 balance, uint256 requested);
    error InsufficientDebt(address asset, address account);
    error RiskEngineNotConfigured();
    error UnauthorizedSupplyToken(address caller, address expected);
    error AccountNotLiquidatable(address account);
    error InvalidLiquidationPair();
    error ReserveAmountExceeded(uint256 reserves, uint256 requested);
    error UnexpectedTokenBalance(address asset, uint256 expected, uint256 received);
    error NumericOverflow(uint256 value);

    event MarketListed(
        address indexed asset,
        address indexed supplyToken,
        address indexed priceFeed,
        address rateModel
    );
    event MarketStatusUpdated(address indexed asset, DataTypes.MarketStatus status);
    event MarketCapsUpdated(address indexed asset, uint256 supplyCap, uint256 borrowCap);
    event MarketRiskUpdated(
        address indexed asset,
        uint256 loanToValueBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        uint256 closeFactorBps
    );
    event MarketSourcesUpdated(
        address indexed asset,
        address indexed priceFeed,
        address indexed rateModel,
        uint256 priceMaxAge
    );
    event ReserveFactorUpdated(address indexed asset, uint256 reserveFactorBps);
    event BorrowingUpdated(address indexed asset, bool enabled);
    event RiskEngineUpdated(address indexed previousEngine, address indexed newEngine);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ProtocolPauseUpdated(bool paused);
    event InterestAccrued(
        address indexed asset,
        uint256 interestAccrued,
        uint256 reservesAccrued,
        uint256 borrowIndex,
        uint256 supplyIndex
    );
    event Supplied(
        address indexed asset,
        address indexed payer,
        address indexed beneficiary,
        uint256 assets,
        uint256 shares
    );
    event Withdrawn(
        address indexed asset,
        address indexed account,
        address indexed recipient,
        uint256 assets,
        uint256 shares
    );
    event Borrowed(
        address indexed asset,
        address indexed borrower,
        address indexed recipient,
        uint256 amount,
        uint256 accountDebt
    );
    event Repaid(
        address indexed asset,
        address indexed payer,
        address indexed borrower,
        uint256 amount,
        uint256 remainingDebt
    );
    event Liquidated(
        address indexed liquidator,
        address indexed account,
        address indexed debtAsset,
        address collateralAsset,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 sharesSeized
    );
    event ReservesClaimed(address indexed asset, address indexed recipient, uint256 amount);
    event BorrowRoundingSurplus(address indexed asset, uint256 amount);

    constructor(
        address initialAdmin,
        address initialTreasury
    ) ProtocolAccess(initialAdmin) {
        if (initialTreasury == address(0)) revert ZeroAddress();
        treasury = initialTreasury;
        _grantRole(TREASURY_ROLE, initialTreasury);
        emit TreasuryUpdated(address(0), initialTreasury);
    }

    modifier whenOperational() {
        if (protocolPaused) revert ProtocolIsPaused();
        _;
    }

    modifier onlyListed(
        address asset
    ) {
        _requireListed(asset);
        _;
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    function listMarket(
        address asset,
        string calldata supplyTokenName,
        string calldata supplyTokenSymbol,
        DataTypes.MarketConfig calldata parameters
    ) external onlyRole(CONFIGURATOR_ROLE) returns (address supplyToken) {
        if (asset == address(0) || asset.code.length == 0) revert InvalidMarketAsset(asset);
        if (_isListed(asset)) revert MarketAlreadyListed(asset);

        uint8 decimals = IERC20(asset).decimals();
        DataTypes.MarketConfig memory config = parameters;
        config.supplyToken = address(0);
        config.assetDecimals = decimals;
        config.status = DataTypes.MarketStatus.Active;
        _validateConfiguration(config);

        supplyToken = address(
            new KairoSupplyToken(address(this), asset, supplyTokenName, supplyTokenSymbol, decimals)
        );
        config.supplyToken = supplyToken;

        _marketConfigs[asset] = config;
        _marketStates[asset] = DataTypes.MarketState({
            totalSupplyAssets: 0,
            totalBorrowAssets: 0,
            totalReserves: 0,
            borrowIndex: _toUint128(RAY),
            supplyIndex: _toUint128(RAY),
            lastAccrual: _toUint40(block.timestamp)
        });
        _marketList.push(asset);

        emit MarketListed(asset, supplyToken, config.priceFeed, config.rateModel);
    }

    function setRiskEngine(
        address newRiskEngine
    ) external onlyRole(CONFIGURATOR_ROLE) {
        if (newRiskEngine == address(0) || newRiskEngine.code.length == 0) revert ZeroAddress();
        address previous = address(riskEngine);
        riskEngine = IKairoRiskEngine(newRiskEngine);
        emit RiskEngineUpdated(previous, newRiskEngine);
    }

    function setTreasury(
        address newTreasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previous = treasury;
        treasury = newTreasury;
        _revokeRole(TREASURY_ROLE, previous);
        _grantRole(TREASURY_ROLE, newTreasury);
        emit TreasuryUpdated(previous, newTreasury);
    }

    function setProtocolPaused(
        bool paused
    ) external onlyRole(GUARDIAN_ROLE) {
        protocolPaused = paused;
        emit ProtocolPauseUpdated(paused);
    }

    function setMarketStatus(
        address asset,
        DataTypes.MarketStatus status
    ) external onlyRole(GUARDIAN_ROLE) onlyListed(asset) {
        if (status == DataTypes.MarketStatus.Unlisted) revert InvalidMarketConfiguration();
        _marketConfigs[asset].status = status;
        emit MarketStatusUpdated(asset, status);
    }

    function setBorrowingEnabled(
        address asset,
        bool enabled
    ) external onlyRole(CONFIGURATOR_ROLE) onlyListed(asset) {
        _marketConfigs[asset].borrowingEnabled = enabled;
        emit BorrowingUpdated(asset, enabled);
    }

    function setMarketCaps(
        address asset,
        uint128 supplyCap,
        uint128 borrowCap
    ) external onlyRole(CONFIGURATOR_ROLE) onlyListed(asset) {
        if (supplyCap == 0 || borrowCap > supplyCap) revert InvalidMarketConfiguration();
        DataTypes.MarketState memory state = _previewMarketState(asset);
        if (state.totalSupplyAssets > supplyCap || state.totalBorrowAssets > borrowCap) {
            revert InvalidMarketConfiguration();
        }
        _marketConfigs[asset].supplyCap = supplyCap;
        _marketConfigs[asset].borrowCap = borrowCap;
        emit MarketCapsUpdated(asset, supplyCap, borrowCap);
    }

    function setMarketRiskParameters(
        address asset,
        uint16 loanToValueBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 closeFactorBps
    ) external onlyRole(CONFIGURATOR_ROLE) onlyListed(asset) {
        _validateRiskParameters(
            loanToValueBps, liquidationThresholdBps, liquidationBonusBps, closeFactorBps
        );
        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        config.loanToValueBps = loanToValueBps;
        config.liquidationThresholdBps = liquidationThresholdBps;
        config.liquidationBonusBps = liquidationBonusBps;
        config.closeFactorBps = closeFactorBps;
        emit MarketRiskUpdated(
            asset, loanToValueBps, liquidationThresholdBps, liquidationBonusBps, closeFactorBps
        );
    }

    function setMarketSources(
        address asset,
        address priceFeed,
        address rateModel,
        uint40 priceMaxAge
    ) external onlyRole(CONFIGURATOR_ROLE) onlyListed(asset) {
        if (
            priceFeed == address(0) || priceFeed.code.length == 0 || rateModel == address(0)
                || rateModel.code.length == 0 || priceMaxAge == 0
        ) revert InvalidMarketConfiguration();

        _accrueMarket(asset);
        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        config.priceFeed = priceFeed;
        config.rateModel = rateModel;
        config.priceMaxAge = priceMaxAge;
        emit MarketSourcesUpdated(asset, priceFeed, rateModel, priceMaxAge);
    }

    function setReserveFactor(
        address asset,
        uint16 reserveFactorBps
    ) external onlyRole(CONFIGURATOR_ROLE) onlyListed(asset) {
        if (reserveFactorBps > BPS) revert InvalidMarketConfiguration();
        _accrueMarket(asset);
        _marketConfigs[asset].reserveFactorBps = reserveFactorBps;
        emit ReserveFactorUpdated(asset, reserveFactorBps);
    }

    // -------------------------------------------------------------------------
    // Supplier operations
    // -------------------------------------------------------------------------

    function supply(
        address asset,
        uint256 assets,
        address beneficiary
    ) external nonReentrant whenOperational onlyListed(asset) returns (uint256 shares) {
        if (assets == 0 || beneficiary == address(0)) revert InvalidAmount();
        _requireActive(asset);
        _accrueMarket(asset);

        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        DataTypes.MarketState storage state = _marketStates[asset];
        uint256 nextTotalAssets = uint256(state.totalSupplyAssets) + assets;
        if (nextTotalAssets > config.supplyCap) {
            revert SupplyCapExceeded(asset, config.supplyCap, nextTotalAssets);
        }

        KairoSupplyToken receipt = KairoSupplyToken(config.supplyToken);
        shares = MarketMath.assetsToShares(
            assets, state.totalSupplyAssets, receipt.totalSupply(), false
        );
        if (shares == 0) revert InvalidAmount();

        _pullExact(asset, msg.sender, assets);
        state.totalSupplyAssets = _toUint128(nextTotalAssets);
        receipt.mint(beneficiary, shares);

        emit Supplied(asset, msg.sender, beneficiary, assets, shares);
    }

    function withdraw(
        address asset,
        uint256 assets,
        address recipient
    ) external nonReentrant onlyListed(asset) returns (uint256 shares) {
        if (assets == 0 || recipient == address(0)) revert InvalidAmount();
        _accrueMarket(asset);

        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        DataTypes.MarketState storage state = _marketStates[asset];
        KairoSupplyToken receipt = KairoSupplyToken(config.supplyToken);
        shares =
            MarketMath.assetsToShares(assets, state.totalSupplyAssets, receipt.totalSupply(), true);
        _validateShareBalance(receipt, msg.sender, shares);
        _validateLiquidity(asset, assets);
        _riskController().validateCollateralReduction(msg.sender, asset, assets);

        receipt.burn(msg.sender, shares);
        state.totalSupplyAssets = _toUint128(uint256(state.totalSupplyAssets) - assets);
        asset.safeTransfer(recipient, assets);

        emit Withdrawn(asset, msg.sender, recipient, assets, shares);
    }

    function redeem(
        address asset,
        uint256 shares,
        address recipient
    ) external nonReentrant onlyListed(asset) returns (uint256 assets) {
        if (shares == 0 || recipient == address(0)) revert InvalidAmount();
        _accrueMarket(asset);

        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        DataTypes.MarketState storage state = _marketStates[asset];
        KairoSupplyToken receipt = KairoSupplyToken(config.supplyToken);
        _validateShareBalance(receipt, msg.sender, shares);

        assets = MarketMath.sharesToAssets(
            shares, state.totalSupplyAssets, receipt.totalSupply(), false
        );
        if (assets == 0) revert InvalidAmount();
        _validateLiquidity(asset, assets);
        _riskController().validateCollateralReduction(msg.sender, asset, assets);

        receipt.burn(msg.sender, shares);
        state.totalSupplyAssets = _toUint128(uint256(state.totalSupplyAssets) - assets);
        asset.safeTransfer(recipient, assets);

        emit Withdrawn(asset, msg.sender, recipient, assets, shares);
    }

    // -------------------------------------------------------------------------
    // Borrower operations
    // -------------------------------------------------------------------------

    function borrow(
        address asset,
        uint256 amount,
        address recipient
    ) external nonReentrant whenOperational onlyListed(asset) returns (uint256 accountDebt) {
        if (amount == 0 || recipient == address(0)) revert InvalidAmount();
        _requireBorrowing(asset);
        _accrueMarket(asset);

        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        DataTypes.MarketState storage state = _marketStates[asset];
        uint256 nextTotalBorrow = uint256(state.totalBorrowAssets) + amount;
        if (nextTotalBorrow > config.borrowCap) {
            revert BorrowCapExceeded(asset, config.borrowCap, nextTotalBorrow);
        }
        _validateLiquidity(asset, amount);
        _riskController().validateBorrow(msg.sender, asset, amount);

        DataTypes.DebtPosition storage position = _debtPositions[asset][msg.sender];
        accountDebt = DebtMath.currentDebt(position, state.borrowIndex) + amount;
        _writeDebtPosition(position, accountDebt, state.borrowIndex);
        state.totalBorrowAssets = _toUint128(nextTotalBorrow);
        asset.safeTransfer(recipient, amount);

        emit Borrowed(asset, msg.sender, recipient, amount, accountDebt);
    }

    function repay(
        address asset,
        uint256 requestedAmount,
        address borrower
    ) external nonReentrant onlyListed(asset) returns (uint256 paid, uint256 remainingDebt) {
        if (requestedAmount == 0 || borrower == address(0)) revert InvalidAmount();

        DataTypes.DebtPosition storage storedPosition = _debtPositions[asset][borrower];
        if (storedPosition.principal == 0) revert InsufficientDebt(asset, borrower);

        uint256 settlementIndex = _marketStates[asset].borrowIndex;
        _accrueMarket(asset);
        DataTypes.MarketState storage state = _marketStates[asset];
        uint256 liveDebt = DebtMath.currentDebt(storedPosition, state.borrowIndex);

        DataTypes.DebtPosition memory updated;
        if (requestedAmount == type(uint256).max || requestedAmount >= liveDebt) {
            paid = liveDebt;
            updated = DataTypes.DebtPosition({
                principal: 0,
                interestIndex: state.borrowIndex,
                lastUpdate: _toUint40(block.timestamp)
            });
        } else {
            (updated, paid) = DebtMath.checkpointAfterRepayment(
                storedPosition, settlementIndex, requestedAmount, block.timestamp
            );
            updated.interestIndex = state.borrowIndex;
        }

        if (paid == 0) revert InvalidAmount();
        _pullExact(asset, msg.sender, paid);
        _debtPositions[asset][borrower] = updated;
        _reduceBorrowAssets(asset, state, paid);
        remainingDebt = updated.principal;

        emit Repaid(asset, msg.sender, borrower, paid, remainingDebt);
    }

    // -------------------------------------------------------------------------
    // Liquidation and reserves
    // -------------------------------------------------------------------------

    function liquidate(
        address collateralAsset,
        address debtAsset,
        address account,
        uint256 requestedRepay
    )
        external
        nonReentrant
        onlyListed(collateralAsset)
        onlyListed(debtAsset)
        returns (uint256, uint256)
    {
        if (
            account == address(0) || account == msg.sender || requestedRepay == 0
                || collateralAsset == debtAsset
        ) revert InvalidLiquidationPair();

        _accrueMarket(debtAsset);
        _accrueMarket(collateralAsset);
        IKairoRiskEngine controller = _riskController();
        if (!controller.isLiquidatable(account)) revert AccountNotLiquidatable(account);

        (uint256 repayAssets, uint256 collateralAssets) =
            controller.liquidationQuote(account, collateralAsset, debtAsset, requestedRepay);
        if (repayAssets == 0 || collateralAssets == 0) revert InvalidAmount();

        repayAssets = _settleLiquidationDebt(debtAsset, account, repayAssets);
        uint256 seizeShares =
            _seizeLiquidationCollateral(collateralAsset, account, collateralAssets, msg.sender);

        emit Liquidated(
            msg.sender,
            account,
            debtAsset,
            collateralAsset,
            repayAssets,
            collateralAssets,
            seizeShares
        );
        return (repayAssets, seizeShares);
    }

    function claimReserves(
        address asset,
        uint256 amount,
        address recipient
    ) external nonReentrant onlyRole(TREASURY_ROLE) onlyListed(asset) {
        if (amount == 0 || recipient == address(0)) revert InvalidAmount();
        _accrueMarket(asset);

        DataTypes.MarketState storage state = _marketStates[asset];
        if (amount > state.totalReserves) {
            revert ReserveAmountExceeded(state.totalReserves, amount);
        }
        uint256 cash = IERC20(asset).balanceOf(address(this));
        if (amount > cash) revert InsufficientLiquidity(asset, cash, amount);

        state.totalReserves = _toUint128(uint256(state.totalReserves) - amount);
        asset.safeTransfer(recipient, amount);
        emit ReservesClaimed(asset, recipient, amount);
    }

    function accrueInterest(
        address asset
    ) external onlyListed(asset) returns (uint256 borrowIndex) {
        _accrueMarket(asset);
        return _marketStates[asset].borrowIndex;
    }

    // -------------------------------------------------------------------------
    // Supply-token validation
    // -------------------------------------------------------------------------

    function validateSupplyTokenTransfer(
        address asset,
        address from,
        address,
        uint256 amount,
        uint256 fromBalanceBefore,
        uint256
    ) external view override onlyListed(asset) {
        address expectedToken = _marketConfigs[asset].supplyToken;
        if (msg.sender != expectedToken) {
            revert UnauthorizedSupplyToken(msg.sender, expectedToken);
        }
        if (from == address(0) || amount == 0) return;
        if (amount > fromBalanceBefore) {
            revert InsufficientShares(from, fromBalanceBefore, amount);
        }

        DataTypes.MarketState memory state = _previewMarketState(asset);
        uint256 totalShares = IERC20(expectedToken).totalSupply();
        uint256 assets = amount == fromBalanceBefore
            ? supplyBalance(asset, from)
            : MarketMath.sharesToAssets(amount, state.totalSupplyAssets, totalShares, true);
        _riskController().validateCollateralReduction(from, asset, assets);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function marketCount() external view override returns (uint256) {
        return _marketList.length;
    }

    function marketAt(
        uint256 index
    ) external view override returns (address) {
        return _marketList[index];
    }

    function getMarketConfig(
        address asset
    ) external view override returns (DataTypes.MarketConfig memory) {
        _requireListed(asset);
        return _marketConfigs[asset];
    }

    function getMarketState(
        address asset
    ) external view override returns (DataTypes.MarketState memory) {
        _requireListed(asset);
        return _previewMarketState(asset);
    }

    function getDebtPosition(
        address asset,
        address account
    ) external view override returns (DataTypes.DebtPosition memory) {
        _requireListed(asset);
        return _debtPositions[asset][account];
    }

    function getAccountLiquidity(
        address account
    ) external view override returns (DataTypes.AccountLiquidity memory) {
        return _riskController().getAccountLiquidity(account);
    }

    function borrowBalance(
        address asset,
        address account
    ) public view override returns (uint256) {
        _requireListed(asset);
        DataTypes.MarketState memory state = _previewMarketState(asset);
        return DebtMath.currentDebt(_debtPositions[asset][account], state.borrowIndex);
    }

    function supplyBalance(
        address asset,
        address account
    ) public view override returns (uint256) {
        _requireListed(asset);
        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        DataTypes.MarketState memory state = _previewMarketState(asset);
        uint256 shares = IERC20(config.supplyToken).balanceOf(account);
        uint256 totalShares = IERC20(config.supplyToken).totalSupply();
        return MarketMath.sharesToAssets(shares, state.totalSupplyAssets, totalShares, false);
    }

    function previewBorrowIndex(
        address asset
    ) external view override returns (uint256) {
        _requireListed(asset);
        return _previewMarketState(asset).borrowIndex;
    }

    function isMarketActive(
        address asset
    ) external view override returns (bool) {
        return _marketConfigs[asset].status == DataTypes.MarketStatus.Active;
    }

    function availableLiquidity(
        address asset
    ) public view returns (uint256) {
        _requireListed(asset);
        uint256 cash = IERC20(asset).balanceOf(address(this));
        DataTypes.MarketState memory state = _previewMarketState(asset);
        return MarketMath.availableLiquidity(cash, state.totalReserves);
    }

    function exchangeRate(
        address asset
    ) external view returns (uint256) {
        _requireListed(asset);
        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        DataTypes.MarketState memory state = _previewMarketState(asset);
        return MarketMath.exchangeRate(
            state.totalSupplyAssets, IERC20(config.supplyToken).totalSupply()
        );
    }

    function previewRates(
        address asset
    ) external view returns (uint256 borrowRateRay, uint256 supplyRateRay) {
        _requireListed(asset);
        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        DataTypes.MarketState memory state = _previewMarketState(asset);
        uint256 cash = IERC20(asset).balanceOf(address(this));
        borrowRateRay = IRateModel(config.rateModel)
            .getBorrowRate(cash, state.totalBorrowAssets, state.totalReserves);
        supplyRateRay = IRateModel(config.rateModel)
            .getSupplyRate(
                cash, state.totalBorrowAssets, state.totalReserves, config.reserveFactorBps
            );
    }

    // -------------------------------------------------------------------------
    // Internal accounting
    // -------------------------------------------------------------------------

    function _accrueMarket(
        address asset
    ) internal {
        DataTypes.MarketState memory current = _marketStates[asset];
        DataTypes.MarketState memory updated = _previewMarketState(asset);
        if (updated.lastAccrual == current.lastAccrual) return;

        uint256 interestAccrued =
            uint256(updated.totalBorrowAssets) - uint256(current.totalBorrowAssets);
        uint256 reservesAccrued = uint256(updated.totalReserves) - uint256(current.totalReserves);
        _marketStates[asset] = updated;

        emit InterestAccrued(
            asset, interestAccrued, reservesAccrued, updated.borrowIndex, updated.supplyIndex
        );
    }

    function _previewMarketState(
        address asset
    ) internal view returns (DataTypes.MarketState memory updated) {
        updated = _marketStates[asset];
        uint256 elapsed = block.timestamp - updated.lastAccrual;
        if (elapsed == 0) return updated;

        updated.lastAccrual = _toUint40(block.timestamp);
        if (updated.totalBorrowAssets == 0) return updated;

        DataTypes.MarketConfig storage config = _marketConfigs[asset];
        uint256 cash = IERC20(asset).balanceOf(address(this));
        uint256 borrowRate = IRateModel(config.rateModel)
            .getBorrowRate(cash, updated.totalBorrowAssets, updated.totalReserves);
        uint256 supplyRate = IRateModel(config.rateModel)
            .getSupplyRate(
                cash, updated.totalBorrowAssets, updated.totalReserves, config.reserveFactorBps
            );

        uint256 nextBorrowIndex = DebtMath.nextBorrowIndex(updated.borrowIndex, borrowRate, elapsed);
        uint256 nextSupplyIndex = DebtMath.nextBorrowIndex(updated.supplyIndex, supplyRate, elapsed);
        uint256 growthFactor = DebtMath.linearInterestFactor(borrowRate, elapsed);
        uint256 nextBorrowAssets = uint256(updated.totalBorrowAssets).rayMul(growthFactor);
        uint256 accrued = nextBorrowAssets - updated.totalBorrowAssets;
        uint256 reserveAccrued = MarketMath.reserveAccrual(accrued, config.reserveFactorBps);

        updated.totalBorrowAssets = _toUint128(nextBorrowAssets);
        updated.totalSupplyAssets =
            _toUint128(uint256(updated.totalSupplyAssets) + accrued - reserveAccrued);
        updated.totalReserves = _toUint128(uint256(updated.totalReserves) + reserveAccrued);
        updated.borrowIndex = _toUint128(nextBorrowIndex);
        updated.supplyIndex = _toUint128(nextSupplyIndex);
    }

    function _writeDebtPosition(
        DataTypes.DebtPosition storage position,
        uint256 principal,
        uint256 interestIndex
    ) internal {
        position.principal = _toUint128(principal);
        position.interestIndex = _toUint128(interestIndex);
        position.lastUpdate = _toUint40(block.timestamp);
    }

    function _settleLiquidationDebt(
        address debtAsset,
        address account,
        uint256 quotedRepay
    ) internal returns (uint256 repayAssets) {
        DataTypes.MarketState storage state = _marketStates[debtAsset];
        DataTypes.DebtPosition storage position = _debtPositions[debtAsset][account];
        uint256 currentDebt = DebtMath.currentDebt(position, state.borrowIndex);
        repayAssets = quotedRepay > currentDebt ? currentDebt : quotedRepay;
        if (repayAssets == 0) revert InvalidAmount();

        _pullExact(debtAsset, msg.sender, repayAssets);
        _writeDebtPosition(position, currentDebt - repayAssets, state.borrowIndex);
        _reduceBorrowAssets(debtAsset, state, repayAssets);
    }

    function _seizeLiquidationCollateral(
        address collateralAsset,
        address account,
        uint256 collateralAssets,
        address recipient
    ) internal returns (uint256 seizeShares) {
        DataTypes.MarketConfig storage config = _marketConfigs[collateralAsset];
        DataTypes.MarketState storage state = _marketStates[collateralAsset];
        KairoSupplyToken token = KairoSupplyToken(config.supplyToken);
        seizeShares = MarketMath.assetsToShares(
            collateralAssets, state.totalSupplyAssets, token.totalSupply(), true
        );
        uint256 accountShares = token.balanceOf(account);
        if (seizeShares > accountShares) seizeShares = accountShares;
        if (seizeShares == 0) revert InvalidAmount();
        token.transferOnLiquidation(account, recipient, seizeShares);
    }

    function _reduceBorrowAssets(
        address asset,
        DataTypes.MarketState storage state,
        uint256 reduction
    ) internal {
        uint256 aggregate = state.totalBorrowAssets;
        if (reduction <= aggregate) {
            state.totalBorrowAssets = _toUint128(aggregate - reduction);
            return;
        }

        uint256 roundingSurplus = reduction - aggregate;
        state.totalBorrowAssets = 0;
        state.totalReserves = _toUint128(uint256(state.totalReserves) + roundingSurplus);
        emit BorrowRoundingSurplus(asset, roundingSurplus);
    }

    function _pullExact(
        address asset,
        address payer,
        uint256 amount
    ) internal {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        asset.safeTransferFrom(payer, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert UnexpectedTokenBalance(asset, amount, received);
    }

    function _validateLiquidity(
        address asset,
        uint256 amount
    ) internal view {
        uint256 available = availableLiquidity(asset);
        if (amount > available) revert InsufficientLiquidity(asset, available, amount);
    }

    function _validateShareBalance(
        KairoSupplyToken token,
        address account,
        uint256 shares
    ) internal view {
        uint256 balance = token.balanceOf(account);
        if (shares > balance) revert InsufficientShares(account, balance, shares);
    }

    function _riskController() internal view returns (IKairoRiskEngine controller) {
        controller = riskEngine;
        if (address(controller) == address(0)) revert RiskEngineNotConfigured();
    }

    function _requireListed(
        address asset
    ) internal view {
        if (!_isListed(asset)) revert MarketNotListed(asset);
    }

    function _requireActive(
        address asset
    ) internal view {
        if (_marketConfigs[asset].status != DataTypes.MarketStatus.Active) {
            revert MarketNotActive(asset);
        }
    }

    function _requireBorrowing(
        address asset
    ) internal view {
        _requireActive(asset);
        if (!_marketConfigs[asset].borrowingEnabled) revert BorrowingDisabled(asset);
    }

    function _isListed(
        address asset
    ) internal view returns (bool) {
        return _marketConfigs[asset].status != DataTypes.MarketStatus.Unlisted;
    }

    function _validateConfiguration(
        DataTypes.MarketConfig memory config
    ) internal view {
        if (
            config.priceFeed == address(0) || config.priceFeed.code.length == 0
                || config.rateModel == address(0) || config.rateModel.code.length == 0
                || config.supplyCap == 0 || config.borrowCap > config.supplyCap
                || config.priceMaxAge == 0 || config.assetDecimals > 36
                || config.reserveFactorBps > BPS
        ) revert InvalidMarketConfiguration();
        _validateRiskParameters(
            config.loanToValueBps,
            config.liquidationThresholdBps,
            config.liquidationBonusBps,
            config.closeFactorBps
        );
    }

    function _validateRiskParameters(
        uint256 loanToValueBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        uint256 closeFactorBps
    ) internal pure {
        if (
            loanToValueBps > liquidationThresholdBps || liquidationThresholdBps > BPS
                || liquidationBonusBps > 5000 || closeFactorBps == 0 || closeFactorBps > BPS
        ) revert InvalidMarketConfiguration();
    }

    function _toUint128(
        uint256 value
    ) internal pure returns (uint128) {
        if (value > type(uint128).max) revert NumericOverflow(value);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    function _toUint40(
        uint256 value
    ) internal pure returns (uint40) {
        if (value > type(uint40).max) revert NumericOverflow(value);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(value);
    }
}
