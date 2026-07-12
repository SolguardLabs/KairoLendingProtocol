// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ProtocolAccess
/// @notice Lightweight role manager with a two-step administrator handover.
abstract contract ProtocolAccess {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    mapping(bytes32 role => mapping(address account => bool enabled)) private _roles;

    address public protocolAdmin;
    address public pendingProtocolAdmin;

    error AccessDenied(bytes32 role, address account);
    error InvalidAccessAccount();
    error PendingAdminOnly();
    error LastAdmin();

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCancelled(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    constructor(
        address initialAdmin
    ) {
        if (initialAdmin == address(0)) revert InvalidAccessAccount();

        protocolAdmin = initialAdmin;
        _roles[DEFAULT_ADMIN_ROLE][initialAdmin] = true;
        _roles[CONFIGURATOR_ROLE][initialAdmin] = true;
        _roles[GUARDIAN_ROLE][initialAdmin] = true;
        _roles[TREASURY_ROLE][initialAdmin] = true;

        emit RoleGranted(DEFAULT_ADMIN_ROLE, initialAdmin, initialAdmin);
        emit RoleGranted(CONFIGURATOR_ROLE, initialAdmin, initialAdmin);
        emit RoleGranted(GUARDIAN_ROLE, initialAdmin, initialAdmin);
        emit RoleGranted(TREASURY_ROLE, initialAdmin, initialAdmin);
    }

    modifier onlyRole(
        bytes32 role
    ) {
        _checkRole(role, msg.sender);
        _;
    }

    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _;
    }

    function hasRole(
        bytes32 role,
        address account
    ) public view returns (bool) {
        return _roles[role][account];
    }

    function checkRole(
        bytes32 role,
        address account
    ) external view {
        _checkRole(role, account);
    }

    function grantRole(
        bytes32 role,
        address account
    ) external onlyAdmin {
        if (account == address(0)) revert InvalidAccessAccount();
        _grantRole(role, account);
    }

    function revokeRole(
        bytes32 role,
        address account
    ) external onlyAdmin {
        if (role == DEFAULT_ADMIN_ROLE && account == protocolAdmin) revert LastAdmin();
        _revokeRole(role, account);
    }

    function renounceRole(
        bytes32 role
    ) external {
        if (role == DEFAULT_ADMIN_ROLE && msg.sender == protocolAdmin) revert LastAdmin();
        _revokeRole(role, msg.sender);
    }

    function beginAdminTransfer(
        address nextAdmin
    ) external onlyAdmin {
        if (nextAdmin == address(0) || nextAdmin == protocolAdmin) {
            revert InvalidAccessAccount();
        }

        pendingProtocolAdmin = nextAdmin;
        emit AdminTransferStarted(protocolAdmin, nextAdmin);
    }

    function cancelAdminTransfer() external onlyAdmin {
        address pending = pendingProtocolAdmin;
        pendingProtocolAdmin = address(0);
        emit AdminTransferCancelled(protocolAdmin, pending);
    }

    function acceptAdminTransfer() external {
        if (msg.sender != pendingProtocolAdmin) revert PendingAdminOnly();

        address previousAdmin = protocolAdmin;
        address nextAdmin = msg.sender;

        protocolAdmin = nextAdmin;
        pendingProtocolAdmin = address(0);

        _grantRole(DEFAULT_ADMIN_ROLE, nextAdmin);
        _grantRole(CONFIGURATOR_ROLE, nextAdmin);
        _grantRole(GUARDIAN_ROLE, nextAdmin);
        _grantRole(TREASURY_ROLE, nextAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, previousAdmin);

        emit AdminTransferred(previousAdmin, nextAdmin);
    }

    function _checkRole(
        bytes32 role,
        address account
    ) internal view {
        if (!_roles[role][account]) revert AccessDenied(role, account);
    }

    function _grantRole(
        bytes32 role,
        address account
    ) internal {
        if (_roles[role][account]) return;
        _roles[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }

    function _revokeRole(
        bytes32 role,
        address account
    ) internal {
        if (!_roles[role][account]) return;
        _roles[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }
}

