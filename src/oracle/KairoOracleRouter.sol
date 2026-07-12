// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IPriceFeed } from "../interfaces/IPriceFeed.sol";

/// @title KairoOracleRouter
/// @notice Selects a fresh price from a primary and an optional fallback source.
/// @dev Source answers are normalized to `outputDecimals` before comparison and return.
contract KairoOracleRouter is IPriceFeed {
    uint256 private constant BPS = 10_000;
    uint8 private constant MAX_DECIMALS = 77;

    address public admin;
    address public pendingAdmin;

    IPriceFeed public primarySource;
    IPriceFeed public fallbackSource;

    uint40 public maxSourceAge;
    uint16 public maxDeviationBps;
    uint8 public immutable outputDecimals;
    string private _description;
    bool public paused;

    error AdminOnly();
    error PendingAdminOnly();
    error InvalidAdmin();
    error InvalidSource();
    error InvalidSourceAge();
    error InvalidDeviation();
    error InvalidDecimals();
    error OraclePaused();
    error NoValidPrice();
    error SourcesDeviate(uint256 primaryPrice, uint256 fallbackPrice);
    error PriceOverflow();

    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event SourcesUpdated(address indexed primarySource, address indexed fallbackSource);
    event SourceAgeUpdated(uint256 previousMaxAge, uint256 newMaxAge);
    event DeviationUpdated(uint256 previousDeviationBps, uint256 newDeviationBps);
    event PauseUpdated(bool paused);

    struct SourceAnswer {
        uint256 price;
        uint256 updatedAt;
        bool valid;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert AdminOnly();
        _;
    }

    constructor(
        address initialAdmin,
        address primarySource_,
        address fallbackSource_,
        uint40 maxSourceAge_,
        uint16 maxDeviationBps_,
        uint8 outputDecimals_,
        string memory description_
    ) {
        if (initialAdmin == address(0)) revert InvalidAdmin();
        if (outputDecimals_ > MAX_DECIMALS) revert InvalidDecimals();
        _validateSources(primarySource_, fallbackSource_);
        _validateSourceAge(maxSourceAge_);
        _validateDeviation(maxDeviationBps_);

        admin = initialAdmin;
        primarySource = IPriceFeed(primarySource_);
        fallbackSource = IPriceFeed(fallbackSource_);
        maxSourceAge = maxSourceAge_;
        maxDeviationBps = maxDeviationBps_;
        outputDecimals = outputDecimals_;
        _description = description_;

        emit SourcesUpdated(primarySource_, fallbackSource_);
    }

    function decimals() external view returns (uint8) {
        return outputDecimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice Returns the primary answer when both sources agree, otherwise the sole valid answer.
    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        if (paused) revert OraclePaused();

        SourceAnswer memory primary = _readSource(primarySource);
        SourceAnswer memory fallbackAnswer = _readSource(fallbackSource);

        if (primary.valid && fallbackAnswer.valid) {
            if (!_withinDeviation(primary.price, fallbackAnswer.price)) {
                revert SourcesDeviate(primary.price, fallbackAnswer.price);
            }
            return (primary.price, primary.updatedAt);
        }
        if (primary.valid) return (primary.price, primary.updatedAt);
        if (fallbackAnswer.valid) return (fallbackAnswer.price, fallbackAnswer.updatedAt);
        revert NoValidPrice();
    }

    function setSources(
        address primarySource_,
        address fallbackSource_
    ) external onlyAdmin {
        _validateSources(primarySource_, fallbackSource_);
        primarySource = IPriceFeed(primarySource_);
        fallbackSource = IPriceFeed(fallbackSource_);
        emit SourcesUpdated(primarySource_, fallbackSource_);
    }

    function setMaxSourceAge(
        uint40 newMaxSourceAge
    ) external onlyAdmin {
        _validateSourceAge(newMaxSourceAge);
        uint256 previous = maxSourceAge;
        maxSourceAge = newMaxSourceAge;
        emit SourceAgeUpdated(previous, newMaxSourceAge);
    }

    function setMaxDeviationBps(
        uint16 newMaxDeviationBps
    ) external onlyAdmin {
        _validateDeviation(newMaxDeviationBps);
        uint256 previous = maxDeviationBps;
        maxDeviationBps = newMaxDeviationBps;
        emit DeviationUpdated(previous, newMaxDeviationBps);
    }

    function setPaused(
        bool newPaused
    ) external onlyAdmin {
        paused = newPaused;
        emit PauseUpdated(newPaused);
    }

    function beginAdminTransfer(
        address nextAdmin
    ) external onlyAdmin {
        if (nextAdmin == address(0) || nextAdmin == admin) revert InvalidAdmin();
        pendingAdmin = nextAdmin;
        emit AdminTransferStarted(admin, nextAdmin);
    }

    function acceptAdminTransfer() external {
        if (msg.sender != pendingAdmin) revert PendingAdminOnly();
        address previous = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(previous, msg.sender);
    }

    function _readSource(
        IPriceFeed source
    ) internal view returns (SourceAnswer memory answer) {
        if (address(source) == address(0)) return answer;

        uint8 sourceDecimals;
        try source.decimals() returns (uint8 value) {
            sourceDecimals = value;
        } catch {
            return answer;
        }
        if (sourceDecimals > MAX_DECIMALS) return answer;

        uint256 rawPrice;
        try source.latestPrice() returns (uint256 price, uint256 updatedAt) {
            rawPrice = price;
            answer.updatedAt = updatedAt;
        } catch {
            return answer;
        }

        uint256 currentTime = block.timestamp;
        if (
            rawPrice == 0 || answer.updatedAt == 0 || answer.updatedAt > currentTime
                || currentTime - answer.updatedAt > maxSourceAge
        ) return answer;

        (answer.price, answer.valid) = _normalize(rawPrice, sourceDecimals);
        if (answer.price == 0) answer.valid = false;
    }

    function _normalize(
        uint256 price,
        uint8 sourceDecimals
    ) internal view returns (uint256 normalized, bool valid) {
        if (sourceDecimals == outputDecimals) return (price, true);

        if (sourceDecimals < outputDecimals) {
            uint256 factor = 10 ** (outputDecimals - sourceDecimals);
            if (price > type(uint256).max / factor) return (0, false);
            return (price * factor, true);
        }

        uint256 divisor = 10 ** (sourceDecimals - outputDecimals);
        normalized = price / divisor;
        valid = normalized != 0;
    }

    function _withinDeviation(
        uint256 primaryPrice,
        uint256 fallbackPrice
    ) internal view returns (bool) {
        uint256 difference = primaryPrice > fallbackPrice
            ? primaryPrice - fallbackPrice
            : fallbackPrice - primaryPrice;
        if (difference == 0) return true;
        if (primaryPrice == 0) return false;

        uint256 allowed = _mulDivDown(primaryPrice, maxDeviationBps, BPS);
        return difference <= allowed;
    }

    function _mulDivDown(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        if (x == 0 || y == 0) return 0;
        uint256 quotient = x / denominator;
        uint256 remainder = x % denominator;
        if (quotient > type(uint256).max / y) revert PriceOverflow();
        result = quotient * y;
        uint256 tail = remainder * y / denominator;
        if (result > type(uint256).max - tail) revert PriceOverflow();
        return result + tail;
    }

    function _validateSources(
        address primarySource_,
        address fallbackSource_
    ) internal view {
        if (primarySource_ == address(0)) revert InvalidSource();
        if (primarySource_ == address(this) || fallbackSource_ == address(this)) {
            revert InvalidSource();
        }
        if (primarySource_ == fallbackSource_) revert InvalidSource();
        if (primarySource_.code.length == 0) revert InvalidSource();
        if (fallbackSource_ != address(0) && fallbackSource_.code.length == 0) {
            revert InvalidSource();
        }
    }

    function _validateSourceAge(
        uint40 sourceAge
    ) internal pure {
        if (sourceAge == 0) revert InvalidSourceAge();
    }

    function _validateDeviation(
        uint16 deviationBps
    ) internal pure {
        if (deviationBps > BPS) revert InvalidDeviation();
    }
}
