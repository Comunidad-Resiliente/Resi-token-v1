// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IResiToken} from "./interfaces/IResiToken.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ResiToken is
    IResiToken,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable
{
    ///@dev BUILDER_ROLE
    bytes32 public constant BUILDER_ROLE = keccak256("BUILDER_ROLE");

    using EnumerableSet for EnumerableSet.Bytes32Set;
    EnumerableSet.Bytes32Set private _rolesSet;

    /// @dev token decimals
    uint8 private _DECIMALS;
    /// @dev treasury address
    address public TREASURY;

    address public STABLE_TOKEN;

    bool public EXIT_STATE;

    mapping(uint256 serieId => uint256 supplyEmitted) public serieSupplies;
    mapping(uint256 serieId => mapping(address user => uint256 balance)) public userSerieBalance;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _treasury,
        address _token,
        address[] calldata _builders
    ) public initializer {
        if (_treasury == address(0)) revert InvalidAddress(_treasury);
        if (_decimals == 0) revert InvalidDecimals(_decimals);
        if (_token == address(0)) revert InvalidAddress(_token);

        __ERC20_init_unchained(_name, _symbol);
        __ReentrancyGuard_init_unchained();
        __ERC20Burnable_init_unchained();
        __ERC20Pausable_init_unchained();

        _rolesSet.add(BUILDER_ROLE);

        _DECIMALS = _decimals;

        TREASURY = _treasury;

        STABLE_TOKEN = _token;

        _grantRole(DEFAULT_ADMIN_ROLE, TREASURY);
        _setRoleAdmin(BUILDER_ROLE, DEFAULT_ADMIN_ROLE);

        for (uint256 i; i < _builders.length; i++) {
            _addBuilder(_builders[i]);
        }

        emit ResiTokenInitialized(_treasury, _token, _decimals);
    }

    /**************************** GETTERS  ****************************/

    ///@dev Version for upgradeable version
    ///@return version
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    function decimals() public view override(ERC20Upgradeable, IResiToken) returns (uint8) {
        return _DECIMALS;
    }

    function isBuilder(address _builder) public view returns (bool) {
        return hasRole(BUILDER_ROLE, _builder);
    }

    /**************************** SETTERS  ****************************/
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        _unpause();
    }

    function enableExits() external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        EXIT_STATE = true;
        emit ExitStateUpdated(true);
    }

    function disableExits() external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        EXIT_STATE = false;
        emit ExitStateUpdated(false);
    }

    function setValueToken(address _newToken) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (_newToken == address(0)) revert InvalidAddress(_newToken);
        address oldToken = STABLE_TOKEN;
        STABLE_TOKEN = _newToken;
        emit ValueTokenUpdated(oldToken, _newToken);
    }

    function addBuilder(address _builder) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        _addBuilder(_builder);
    }

    function removeBuilder(address _builder) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (_builder == address(0)) {
            revert InvalidAddress(_builder);
        }
        if (!hasRole(BUILDER_ROLE, _builder)) {
            revert InvalidBuilder(_builder);
        }
        _revokeRole(BUILDER_ROLE, _builder);

        emit BuilderRemoved(_builder);
    }

    function addBuildersBatch(address[] memory _builders) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        for (uint256 i = 0; i < _builders.length; ++i) {
            _addBuilder(_builders[i]);
        }
    }

    function award(address _to, uint256 _amount, uint256 _serieId) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        _award(_to, _amount, _serieId);
    }

    function awardBatch(
        address[] memory _users,
        uint256[] memory _amounts,
        uint256 _serieId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(_users.length == _amounts.length, "RESIToken: users and amounts length mismatch");
        for (uint256 i = 0; i < _users.length; i++) {
            _award(_users[i], _amounts[i], _serieId);
        }
    }

    function burn(uint256 _value, uint256 _serieId) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (_serieId == 0) revert InvalidSerie(_serieId);
        _burn(address(this), _value);
        serieSupplies[_serieId] -= _value;
        emit ResiTokenBurnt(_value, _serieId);
    }

    function exit(uint256 _serieId) external whenExitIsEnabled nonReentrant {
        _checkExit(_serieId);

        uint256 currentValueTokenBalance = IERC20(STABLE_TOKEN).balanceOf(address(this));
        uint256 userBalance = userSerieBalance[_serieId][_msgSender()];
        uint256 quote = (userBalance * currentValueTokenBalance) / serieSupplies[_serieId];

        if (quote <= currentValueTokenBalance && quote > 0) {
            _transfer(_msgSender(), address(this), userBalance);
            SafeERC20.safeTransfer(IERC20(STABLE_TOKEN), _msgSender(), quote);
            userSerieBalance[_serieId][_msgSender()] = 0;
            emit Exit(_msgSender(), quote, _serieId);
        } else {
            revert InvalidQuote(currentValueTokenBalance, userBalance, serieSupplies[_serieId], quote);
        }
    }

    /**
     *  @dev It is not allowed to transfer resi token
     */
    function transfer(address, uint256) public pure override(ERC20Upgradeable) returns (bool) {
        revert TransferForbidden("RESIToken: NO TRANSFER ALLOWED");
    }

    /**
     * @dev It is not allowed to transfer resi token
     */
    function transferFrom(address, address, uint256) public pure override(ERC20Upgradeable) returns (bool) {
        revert TransferFromForbidden("RESIToken: NO TRANSFER FROM ALLOWED");
    }

    function burn(uint256) public pure override(ERC20BurnableUpgradeable) {
        revert BurnForbbidden();
    }

    function burnFrom(address, uint256) public pure override(ERC20BurnableUpgradeable) {
        revert BurnForbbidden();
    }

    /**************************** INTERNAL  ****************************/
    function _addBuilder(address _builder) internal onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (_builder == address(0)) revert InvalidAddress(_builder);
        if (hasRole(BUILDER_ROLE, _builder)) {
            revert AlreadyBuilder(_builder);
        }
        _grantRole(BUILDER_ROLE, _builder);
        emit BuilderAdded(_builder);
    }

    function _award(
        address _user,
        uint256 _amount,
        uint256 _serieId
    ) internal onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (_serieId == 0) revert InvalidSerie(_serieId);
        if (_user == address(0)) revert InvalidAddress(_user);
        if (_amount == 0) revert InvalidAmount(_amount);
        if (!hasRole(BUILDER_ROLE, _user)) revert InvalidBuilder(_user);
        _mint(_user, _amount);
        serieSupplies[_serieId] += _amount;
        userSerieBalance[_serieId][_user] += _amount;
        emit UserAwarded(_user, _amount, _serieId);
    }

    /**
     * @dev Internal function to perform valid exit
     */
    function _checkExit(uint256 _serieId) internal view {
        if (_msgSender() == TREASURY) revert InvalidAddress(_msgSender());
        if (!hasRole(BUILDER_ROLE, _msgSender())) revert InvalidBuilder(_msgSender());
        if (serieSupplies[_serieId] == 0) revert SerieWithNoMintedSupply(_serieId);
        if (userSerieBalance[_serieId][_msgSender()] == 0)
            revert InvalidUserSerieBalance(userSerieBalance[_serieId][_msgSender()]);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override(ERC20PausableUpgradeable, ERC20Upgradeable) whenNotPaused {
        ERC20PausableUpgradeable._update(from, to, value);
    }

    /**************************** MODIFIERS  ****************************/

    modifier whenExitIsEnabled() {
        require(!paused() && EXIT_STATE, "RESIToken: Exits disabled");
        _;
    }

    /// @dev Leave a gap betweeen inherited contracts variables in order
    /// @dev to be able to add more variables in them later.
    uint256[20] private upgradeGap;
}
