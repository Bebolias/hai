// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {ICollateralAuctionHouse} from '@interfaces/ICollateralAuctionHouse.sol';
import {ISAFESaviour} from '@interfaces/external/ISAFESaviour.sol';
import {ISAFEEngine} from '@interfaces/ISAFEEngine.sol';
import {IAccountingEngine} from '@interfaces/IAccountingEngine.sol';
import {ILiquidationEngine} from '@interfaces/ILiquidationEngine.sol';

import {Authorizable} from '@contracts/utils/Authorizable.sol';
import {Modifiable} from '@contracts/utils/Modifiable.sol';
import {Disableable} from '@contracts/utils/Disableable.sol';

import {ReentrancyGuard} from '@openzeppelin/security/ReentrancyGuard.sol';
import {EnumerableSet} from '@openzeppelin/utils/structs/EnumerableSet.sol';
import {Encoding} from '@libraries/Encoding.sol';
import {Assertions} from '@libraries/Assertions.sol';
import {Math, RAY, WAD, MAX_RAD} from '@libraries/Math.sol';

contract LiquidationEngine is Authorizable, Modifiable, Disableable, ReentrancyGuard, ILiquidationEngine {
  using Math for uint256;
  using Encoding for bytes;
  using Assertions for uint256;
  using Assertions for address;
  using EnumerableSet for EnumerableSet.Bytes32Set;

  // --- SAFE Saviours ---
  // Contracts that can save SAFEs from liquidation
  mapping(address => uint256) public safeSaviours;

  // Saviour contract chosen for each SAFE by its creator
  mapping(bytes32 => mapping(address => address)) public chosenSAFESaviour;

  // Current amount of system coins out for liquidation
  uint256 public currentOnAuctionSystemCoins; // [rad]

  // --- Registry ---
  ISAFEEngine public safeEngine;
  IAccountingEngine public accountingEngine;

  // --- Params ---
  // solhint-disable-next-line private-vars-leading-underscore
  LiquidationEngineParams public _params;
  // solhint-disable-next-line private-vars-leading-underscore
  mapping(bytes32 _cType => LiquidationEngineCollateralParams) public _cParams;

  function params() external view returns (LiquidationEngineParams memory _liqEngineParams) {
    return _params;
  }

  function cParams(bytes32 _cType) external view returns (LiquidationEngineCollateralParams memory _liqEngineCParams) {
    return _cParams[_cType];
  }

  EnumerableSet.Bytes32Set internal _collateralList;

  // --- Init ---
  constructor(
    address _safeEngine,
    address _accountingEngine,
    LiquidationEngineParams memory _liqEngineParams
  ) Authorizable(msg.sender) validParams {
    safeEngine = ISAFEEngine(_safeEngine.assertNonNull());
    accountingEngine = IAccountingEngine(_accountingEngine);

    _params = _liqEngineParams;
  }

  /**
   * @notice Authed function to add contracts that can save SAFEs from liquidation
   * @param  _saviour SAFE saviour contract to be whitelisted
   */
  function connectSAFESaviour(address _saviour) external isAuthorized {
    (bool _ok, uint256 _collateralAdded, uint256 _liquidatorReward) =
      ISAFESaviour(_saviour).saveSAFE(address(this), '', address(0));
    if (!_ok) revert LiqEng_SaviourNotOk();
    if (_collateralAdded != type(uint256).max || _liquidatorReward != type(uint256).max) revert LiqEng_InvalidAmounts();
    safeSaviours[_saviour] = 1;
    emit ConnectSAFESaviour(_saviour);
  }

  /**
   * @notice Governance used function to remove contracts that can save SAFEs from liquidation
   * @param  _saviour SAFE saviour contract to be removed
   */
  function disconnectSAFESaviour(address _saviour) external isAuthorized {
    safeSaviours[_saviour] = 0;
    emit DisconnectSAFESaviour(_saviour);
  }

  // --- SAFE Liquidation ---
  /**
   * @notice Choose a saviour contract for your SAFE
   * @param  _cType The SAFE's collateral type
   * @param  _safe The SAFE's address
   * @param  _saviour The chosen saviour
   */
  function protectSAFE(bytes32 _cType, address _safe, address _saviour) external {
    if (_saviour != address(0)) {
      if (!safeEngine.canModifySAFE(_safe, msg.sender)) revert LiqEng_CannotModifySAFE();
      if (safeSaviours[_saviour] == 0) revert LiqEng_SaviourNotAuthorized();
    }
    chosenSAFESaviour[_cType][_safe] = _saviour;
    emit ProtectSAFE(_cType, _safe, _saviour);
  }

  /**
   * @notice Liquidate a SAFE
   * @param  _cType The SAFE's collateral type
   * @param  _safe The SAFE's address
   */
  function liquidateSAFE(bytes32 _cType, address _safe) external whenEnabled nonReentrant returns (uint256 _auctionId) {
    uint256 _debtFloor = safeEngine.cParams(_cType).debtFloor;
    ISAFEEngine.SAFEEngineCollateralData memory _safeEngCData = safeEngine.cData(_cType);
    ISAFEEngine.SAFE memory _safeData = safeEngine.safes(_cType, _safe);

    // --- Safety checks ---
    {
      if (
        _safeEngCData.liquidationPrice == 0
          || _safeData.lockedCollateral * _safeEngCData.liquidationPrice
            >= _safeData.generatedDebt * _safeEngCData.accumulatedRate
      ) revert LiqEng_SAFENotUnsafe();

      if (
        currentOnAuctionSystemCoins >= _params.onAuctionSystemCoinLimit
          || _params.onAuctionSystemCoinLimit - currentOnAuctionSystemCoins < _debtFloor
      ) revert LiqEng_LiquidationLimitHit();
    }

    if (chosenSAFESaviour[_cType][_safe] != address(0) && safeSaviours[chosenSAFESaviour[_cType][_safe]] == 1) {
      try ISAFESaviour(chosenSAFESaviour[_cType][_safe]).saveSAFE(msg.sender, _cType, _safe) returns (
        bool _ok, uint256 _collateralAddedOrDebtRepaid, uint256
      ) {
        if (_ok && _collateralAddedOrDebtRepaid > 0) {
          // Checks that the saviour didn't take collateral or add more debt to the SAFE
          ISAFEEngine.SAFE memory _newSafeData = safeEngine.safes(_cType, _safe);

          // --- Safety checks ---
          {
            if (
              _newSafeData.lockedCollateral < _safeData.lockedCollateral
                || _newSafeData.generatedDebt > _safeData.generatedDebt
            ) revert LiqEng_InvalidSAFESaviourOperation();
          }

          _safeEngCData = safeEngine.cData(_cType);
          _safeData = _newSafeData;
          emit SaveSAFE(_cType, _safe, _collateralAddedOrDebtRepaid);
        }
      } catch (bytes memory _revertReason) {
        emit FailedSAFESave(_revertReason);
      }
    }

    if (
      _safeData.lockedCollateral * _safeEngCData.liquidationPrice
        < _safeData.generatedDebt * _safeEngCData.accumulatedRate
    ) {
      LiquidationEngineCollateralParams memory __cParams = _cParams[_cType];

      uint256 _limitAdjustedDebt = Math.min(
        _safeData.generatedDebt,
        Math.min(__cParams.liquidationQuantity, _params.onAuctionSystemCoinLimit - currentOnAuctionSystemCoins).wdiv(
          _safeEngCData.accumulatedRate
        ) / __cParams.liquidationPenalty
      );

      uint256 _collateralToSell =
        Math.min(_safeData.lockedCollateral, _safeData.lockedCollateral * _limitAdjustedDebt / _safeData.generatedDebt);
      uint256 _amountToRaise = (_limitAdjustedDebt * _safeEngCData.accumulatedRate).wmul(__cParams.liquidationPenalty);

      // --- Safety checks ---
      {
        if (_limitAdjustedDebt == 0) revert LiqEng_NullAuction();

        if (_collateralToSell == 0) revert LiqEng_NullCollateralToSell();

        if (
          _limitAdjustedDebt != _safeData.generatedDebt
            && (_safeData.generatedDebt - _limitAdjustedDebt) * _safeEngCData.accumulatedRate < _debtFloor
        ) revert LiqEng_DustySAFE();
      }

      safeEngine.confiscateSAFECollateralAndDebt({
        _cType: _cType,
        _safe: _safe,
        _collateralSource: address(this),
        _debtDestination: address(accountingEngine),
        _deltaCollateral: -_collateralToSell.toInt(),
        _deltaDebt: -_limitAdjustedDebt.toInt()
      });

      accountingEngine.pushDebtToQueue(_limitAdjustedDebt * _safeEngCData.accumulatedRate);

      currentOnAuctionSystemCoins += _amountToRaise;

      _auctionId = ICollateralAuctionHouse(__cParams.collateralAuctionHouse).startAuction({
        _forgoneCollateralReceiver: _safe,
        _initialBidder: address(accountingEngine),
        _amountToRaise: _amountToRaise,
        _collateralToSell: _collateralToSell
      });

      emit UpdateCurrentOnAuctionSystemCoins(currentOnAuctionSystemCoins);

      emit Liquidate(
        _cType,
        _safe,
        _collateralToSell,
        _limitAdjustedDebt,
        _limitAdjustedDebt * _safeEngCData.accumulatedRate,
        __cParams.collateralAuctionHouse,
        _auctionId
      );
    }
  }

  /**
   * @notice Initialize a brand new collateral type
   * @param _cType Collateral type name (e.g ETH-A, TBTC-B)
   */
  function initializeCollateralType(
    bytes32 _cType,
    LiquidationEngineCollateralParams memory _liqEngineCParams
  ) external isAuthorized validCParams(_cType) {
    if (!_collateralList.add(_cType)) revert LiqEng_CollateralTypeAlreadyInitialized();
    _setCollateralAuctionHouse(_cType, _liqEngineCParams.collateralAuctionHouse);
    _cParams[_cType] = _liqEngineCParams;
  }

  /**
   * @notice Remove debt that was being auctioned
   * @param  _rad The amount of debt to withdraw from currentOnAuctionSystemCoins
   */
  function removeCoinsFromAuction(uint256 _rad) public isAuthorized {
    currentOnAuctionSystemCoins -= _rad;
    emit UpdateCurrentOnAuctionSystemCoins(currentOnAuctionSystemCoins);
  }

  // --- Getters ---
  /**
   * @notice Get the amount of debt that can currently be covered by a collateral auction for a specific safe
   * @param  _cType The collateral type stored in the SAFE
   * @param  _safe The SAFE's address/handler
   */
  function getLimitAdjustedDebtToCover(
    bytes32 _cType,
    address _safe
  ) external view returns (uint256 _limitAdjustedDebtToCover) {
    uint256 _accumulatedRate = safeEngine.cData(_cType).accumulatedRate;
    uint256 _generatedDebt = safeEngine.safes(_cType, _safe).generatedDebt;
    LiquidationEngineCollateralParams memory __cParams = _cParams[_cType];

    return Math.min(
      _generatedDebt,
      Math.min(__cParams.liquidationQuantity, _params.onAuctionSystemCoinLimit - currentOnAuctionSystemCoins).wdiv(
        _accumulatedRate
      ) / __cParams.liquidationPenalty
    );
  }

  // --- Views ---
  function collateralList() external view returns (bytes32[] memory __collateralList) {
    return _collateralList.values();
  }

  // --- Administration ---
  function _modifyParameters(bytes32 _param, bytes memory _data) internal override {
    if (_param == 'onAuctionSystemCoinLimit') _params.onAuctionSystemCoinLimit = _data.toUint256();
    else if (_param == 'accountingEngine') accountingEngine = IAccountingEngine(_data.toAddress());
    else revert UnrecognizedParam();
  }

  function _modifyParameters(bytes32 _cType, bytes32 _param, bytes memory _data) internal override {
    uint256 _uint256 = _data.toUint256();

    if (!_collateralList.contains(_cType)) revert UnrecognizedCType();
    if (_param == 'liquidationPenalty') _cParams[_cType].liquidationPenalty = _uint256;
    else if (_param == 'liquidationQuantity') _cParams[_cType].liquidationQuantity = _uint256;
    else if (_param == 'collateralAuctionHouse') _setCollateralAuctionHouse(_cType, _data.toAddress());
    else revert UnrecognizedParam();
  }

  function _validateParameters() internal view override {
    address(accountingEngine).assertNonNull();
  }

  function _validateCParameters(bytes32 _cType) internal view override {
    LiquidationEngineCollateralParams memory __cParams = _cParams[_cType];
    address(__cParams.collateralAuctionHouse).assertNonNull();
    __cParams.liquidationQuantity.assertLtEq(MAX_RAD);
  }

  function _setCollateralAuctionHouse(bytes32 _cType, address _newCollateralAuctionHouse) internal {
    LiquidationEngineCollateralParams storage __cParams = _cParams[_cType];
    if (__cParams.collateralAuctionHouse != address(0)) {
      safeEngine.denySAFEModification(__cParams.collateralAuctionHouse);
      _removeAuthorization(__cParams.collateralAuctionHouse);
    }
    __cParams.collateralAuctionHouse = _newCollateralAuctionHouse;
    safeEngine.approveSAFEModification(_newCollateralAuctionHouse);
    _addAuthorization(_newCollateralAuctionHouse);
  }
}
