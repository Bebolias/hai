// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {ICollateralJoin} from '@interfaces/utils/ICollateralJoin.sol';
import {ICollateralAuctionHouse} from '@interfaces/ICollateralAuctionHouse.sol';
import {ISAFEEngine} from '@interfaces/ISAFEEngine.sol';
import {ICoinJoin} from '@interfaces/utils/ICoinJoin.sol';

import {CommonActions} from '@contracts/proxies/actions/CommonActions.sol';

import {RAY} from '@libraries/Math.sol';

/**
 * @title CollateralBidActions
 * @notice All methods here are executed as delegatecalls from the user's proxy
 */
contract CollateralBidActions is CommonActions {
  function buyCollateral(
    address _coinJoin,
    address _collateralJoin,
    address _collateralAuctionHouse,
    uint256 _auctionId,
    uint256 _minCollateralAmount,
    uint256 _bidAmount
  ) external delegateCall {
    ISAFEEngine _safeEngine = ICoinJoin(_coinJoin).safeEngine();
    // checks coin balance and joins more if needed
    uint256 _coinBalance = _safeEngine.coinBalance(address(this)) / RAY;
    if (_coinBalance < _bidAmount) {
      _joinSystemCoins(_coinJoin, address(this), _bidAmount - _coinBalance);
    }

    // collateralAuctionHouse needs to be approved for system coin spending
    if (!_safeEngine.canModifySAFE(address(this), address(_collateralAuctionHouse))) {
      _safeEngine.approveSAFEModification(address(_collateralAuctionHouse));
    }

    bytes32 _cType = ICollateralAuctionHouse(_collateralAuctionHouse).collateralType();
    uint256 _initialCollateralBalance = _safeEngine.tokenCollateral(_cType, address(this));
    ICollateralAuctionHouse(_collateralAuctionHouse).buyCollateral(_auctionId, _bidAmount);
    uint256 _finalCollateralBalance = _safeEngine.tokenCollateral(_cType, address(this));

    uint256 _boughtAmount = _finalCollateralBalance - _initialCollateralBalance;
    require(_boughtAmount >= _minCollateralAmount, 'Invalid bought amount');

    // exit collateral
    _exitCollateral(_collateralJoin, _boughtAmount);
  }
}
