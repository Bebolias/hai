// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IStabilityFeeTreasury} from '@interfaces/IStabilityFeeTreasury.sol';
import {ISAFEEngine} from '@interfaces/ISAFEEngine.sol';
import {ISystemCoin} from '@interfaces/tokens/ISystemCoin.sol';
import {ICoinJoin} from '@interfaces/utils/ICoinJoin.sol';

import {Authorizable} from '@contracts/utils/Authorizable.sol';
import {Modifiable} from '@contracts/utils/Modifiable.sol';
import {Disableable} from '@contracts/utils/Disableable.sol';

import {Encoding} from '@libraries/Encoding.sol';
import {Assertions} from '@libraries/Assertions.sol';
import {Math, RAY, HOUR} from '@libraries/Math.sol';

contract StabilityFeeTreasury is Authorizable, Modifiable, Disableable, IStabilityFeeTreasury {
  using Encoding for bytes;
  using Assertions for uint256;
  using Assertions for address;

  // --- Registry ---
  ISAFEEngine public safeEngine;
  ISystemCoin public systemCoin;
  ICoinJoin public coinJoin;
  address public extraSurplusReceiver;

  // --- Params ---
  // solhint-disable-next-line private-vars-leading-underscore
  StabilityFeeTreasuryParams public _params;

  function params() external view returns (StabilityFeeTreasuryParams memory _sfTreasuryParams) {
    return _params;
  }

  // --- Data ---
  // Mapping of total and per hour allowances
  // solhint-disable-next-line private-vars-leading-underscore
  mapping(address => Allowance) public _allowance;

  function allowance(address _account) external view returns (Allowance memory __allowance) {
    return _allowance[_account];
  }

  // Mapping that keeps track of how much surplus an authorized address has pulled each hour
  mapping(address => mapping(uint256 => uint256)) public pulledPerHour;
  uint256 public latestSurplusTransferTime; // latest timestamp when transferSurplusFunds was called [seconds]

  modifier accountNotTreasury(address _account) {
    if (_account == address(this)) revert SFTreasury_AccountCannotBeTreasury();
    _;
  }

  constructor(
    address _safeEngine,
    address _extraSurplusReceiver,
    address _coinJoin,
    StabilityFeeTreasuryParams memory _sfTreasuryParams
  ) Authorizable(msg.sender) validParams {
    safeEngine = ISAFEEngine(_safeEngine.assertNonNull());
    coinJoin = ICoinJoin(_coinJoin.assertNonNull());
    extraSurplusReceiver = _extraSurplusReceiver;
    systemCoin = ISystemCoin(address(coinJoin.systemCoin()).assertNonNull());
    latestSurplusTransferTime = block.timestamp;
    _params = _sfTreasuryParams;

    systemCoin.approve(address(coinJoin), type(uint256).max);
  }

  // --- Shutdown ---

  /**
   * @notice Disable this contract (normally called by GlobalSettlement)
   */
  function _onContractDisable() internal override {
    _joinAllCoins();
    uint256 _coinBalanceSelf = safeEngine.coinBalance(address(this));
    safeEngine.transferInternalCoins(address(this), extraSurplusReceiver, _coinBalanceSelf);
  }

  /**
   * @notice Join all ERC20 system coins that the treasury has inside the SAFEEngine
   */
  function _joinAllCoins() internal {
    uint256 _systemCoinBalance = systemCoin.balanceOf(address(this));
    if (_systemCoinBalance > 0) {
      coinJoin.join(address(this), _systemCoinBalance);
      emit JoinCoins(_systemCoinBalance);
    }
  }

  /**
   * @notice Settle as much bad debt as possible (if this contract has any)
   */
  function settleDebt() external returns (uint256 _coinBalance, uint256 _debtBalance) {
    return _settleDebt();
  }

  function _settleDebt() internal returns (uint256 _coinBalance, uint256 _debtBalance) {
    _coinBalance = safeEngine.coinBalance(address(this));
    _debtBalance = safeEngine.debtBalance(address(this));
    if (_debtBalance > 0) {
      uint256 _debtToSettle = Math.min(_coinBalance, _debtBalance);
      _coinBalance -= _debtToSettle;
      _debtBalance -= _debtToSettle;
      safeEngine.settleDebt(_debtToSettle);
      emit SettleDebt(_debtToSettle);
    }
  }

  // --- SF Transfer Allowance ---
  /**
   * @notice Modify an address' total allowance in order to withdraw SF from the treasury
   * @param  _account The approved address
   * @param  _rad The total approved amount of SF to withdraw (number with 45 decimals)
   */
  function setTotalAllowance(address _account, uint256 _rad) external isAuthorized accountNotTreasury(_account) {
    _allowance[_account.assertNonNull()].total = _rad;
    emit SetTotalAllowance(_account, _rad);
  }

  /**
   * @notice Modify an address' per hour allowance in order to withdraw SF from the treasury
   * @param  _account The approved address
   * @param  _rad The per hour approved amount of SF to withdraw (number with 45 decimals)
   */
  function setPerHourAllowance(address _account, uint256 _rad) external isAuthorized accountNotTreasury(_account) {
    _allowance[_account.assertNonNull()].perHour = _rad;
    emit SetPerHourAllowance(_account, _rad);
  }

  // --- Stability Fee Transfer (Governance) ---
  /**
   * @notice Governance transfers SF to an address
   * @param  _account Address to transfer SF to
   * @param  _rad Amount of internal system coins to transfer (a number with 45 decimals)
   */
  function giveFunds(address _account, uint256 _rad) external isAuthorized accountNotTreasury(_account) {
    _account.assertNonNull();
    _joinAllCoins();
    (uint256 _coinBalance, uint256 _debtBalance) = _settleDebt();

    if (_debtBalance != 0) revert SFTreasury_OutstandingBadDebt();
    if (_coinBalance < _rad) revert SFTreasury_NotEnoughFunds();

    safeEngine.transferInternalCoins(address(this), _account, _rad);
    emit GiveFunds(_account, _rad);
  }

  /**
   * @notice Governance takes funds from an address
   * @param  _account Address to take system coins from
   * @param  _rad Amount of internal system coins to take from the account (a number with 45 decimals)
   */
  function takeFunds(address _account, uint256 _rad) external isAuthorized accountNotTreasury(_account) {
    safeEngine.transferInternalCoins(_account, address(this), _rad);
    emit TakeFunds(_account, _rad);
  }

  // --- Stability Fee Transfer (Approved Accounts) ---
  /**
   * @notice Pull stability fees from the treasury (if your allowance permits)
   * @param  _dstAccount Address to transfer funds to
   * @param  _wad Amount of system coins (SF) to transfer (expressed as an 18 decimal number but the contract will transfer
   *             internal system coins that have 45 decimals)
   */
  function pullFunds(address _dstAccount, uint256 _wad) external {
    if (_dstAccount.assertNonNull() == address(this)) return;
    if (_dstAccount == extraSurplusReceiver) revert SFTreasury_DstCannotBeAccounting();
    if (_wad == 0) revert SFTreasury_NullTransferAmount();
    if (_allowance[msg.sender].total < _wad * RAY) revert SFTreasury_NotAllowed();
    if (_allowance[msg.sender].perHour > 0) {
      if (_allowance[msg.sender].perHour < pulledPerHour[msg.sender][block.timestamp / HOUR] + (_wad * RAY)) {
        revert SFTreasury_PerHourLimitExceeded();
      }
    }

    pulledPerHour[msg.sender][block.timestamp / HOUR] += (_wad * RAY);

    _joinAllCoins();
    (uint256 _coinBalance, uint256 _debtBalance) = _settleDebt();

    if (_debtBalance != 0) revert SFTreasury_OutstandingBadDebt();
    if (_coinBalance < _wad * RAY) revert SFTreasury_NotEnoughFunds();
    if (_coinBalance < _params.pullFundsMinThreshold) revert SFTreasury_BelowPullFundsMinThreshold();

    // Update allowance
    _allowance[msg.sender].total -= (_wad * RAY);

    // Transfer money
    safeEngine.transferInternalCoins(address(this), _dstAccount, _wad * RAY);

    emit PullFunds(msg.sender, _dstAccount, _wad * RAY);
  }

  // --- Treasury Maintenance ---
  /**
   * @notice Transfer surplus stability fees to the extraSurplusReceiver. This is here to make sure that the treasury
   *              doesn't accumulate fees that it doesn't even need in order to pay for allowances. It ensures
   *              that there are enough funds left in the treasury to account for posterior expenses
   */
  function transferSurplusFunds() external {
    if (block.timestamp < latestSurplusTransferTime + _params.surplusTransferDelay) {
      revert SFTreasury_TransferCooldownNotPassed();
    }
    // Join all coins in system
    _joinAllCoins();
    // Settle outstanding bad debt
    (uint256 _coinBalance, uint256 _debtBalance) = _settleDebt();

    // Check that there's no bad debt left
    if (_debtBalance != 0) revert SFTreasury_OutstandingBadDebt();
    // Check if we have too much money
    if (_coinBalance <= _params.treasuryCapacity) revert SFTreasury_NotEnoughSurplus();

    // Set internal vars
    latestSurplusTransferTime = block.timestamp;
    // Make sure that we still keep min SF in treasury
    uint256 _fundsToTransfer = _coinBalance - _params.treasuryCapacity;
    // Transfer surplus to accounting engine
    safeEngine.transferInternalCoins(address(this), extraSurplusReceiver, _fundsToTransfer);
    // Emit event
    emit TransferSurplusFunds(extraSurplusReceiver, _fundsToTransfer);
  }

  // --- Administration ---

  function _modifyParameters(bytes32 _param, bytes memory _data) internal override whenEnabled {
    uint256 _uint256 = _data.toUint256();

    if (_param == 'extraSurplusReceiver') extraSurplusReceiver = _data.toAddress();
    else if (_param == 'treasuryCapacity') _params.treasuryCapacity = _uint256;
    else if (_param == 'pullFundsMinThreshold') _params.pullFundsMinThreshold = _uint256;
    else if (_param == 'surplusTransferDelay') _params.surplusTransferDelay = _uint256;
    else revert UnrecognizedParam();
  }

  function _validateParameters() internal view override {
    extraSurplusReceiver.assertNonNull();
  }
}
