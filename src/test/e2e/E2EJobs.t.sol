// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {Common, ETH_A, COLLAT, DEBT} from './Common.t.sol';
import {JOB_REWARD} from '@script/Params.s.sol';

import {AccountingJob, IAccountingJob} from '@contracts/jobs/AccountingJob.sol';
import {LiquidationJob, ILiquidationJob} from '@contracts/jobs/LiquidationJob.sol';
import {OracleJob, IOracleJob} from '@contracts/jobs/OracleJob.sol';

import {RAY, YEAR} from '@libraries/Math.sol';

import {BaseUser} from '@test/scopes/BaseUser.t.sol';
import {DirectUser} from '@test/scopes/DirectUser.t.sol';
import {ProxyUser} from '@test/scopes/ProxyUser.t.sol';

abstract contract E2EJobsTest is BaseUser, Common {
  function setUp() public override {
    super.setUp();

    // Opening a SAFE to generate stability fees
    address alice = address(0x420);
    vm.deal(alice, COLLAT);
    vm.startPrank(alice);
    safeEngine.approveSAFEModification(address(collateralJoin[ETH_A]));
    ethJoin.join{value: COLLAT}(alice);
    safeEngine.modifySAFECollateralization({
      _cType: ETH_A,
      _safe: alice,
      _collateralSource: alice,
      _debtDestination: alice,
      _deltaCollateral: int256(COLLAT),
      _deltaDebt: int256(DEBT)
    });
    vm.stopPrank();

    // Collecting fees for stabilityFeeTreasury
    _collectFees(ETH_A, YEAR * 10);
  }

  function test_work_pop_debt_from_queue(uint256 _debtBlock) public {
    vm.assume(_debtBlock != 0);
    vm.prank(deployer);
    accountingEngine.pushDebtToQueue(_debtBlock);
    uint256 _debtTimestamp = block.timestamp;
    vm.warp(_debtTimestamp + accountingEngine.params().popDebtDelay);

    uint256 _initialBalance = systemCoin.balanceOf(address(this));
    _workPopDebtFromQueue(address(this), _debtTimestamp);

    assertEq(systemCoin.balanceOf(address(this)) - _initialBalance, JOB_REWARD);
  }

  function test_work_auction_debt() public {
    liquidationEngine.liquidateSAFE(ETH_A, alice);
    accountingEngine.popDebtFromQueue(block.timestamp);

    uint256 _initialBalance = systemCoin.balanceOf(address(this));
    _workAuctionDebt(address(this));

    assertEq(systemCoin.balanceOf(address(this)) - _initialBalance, JOB_REWARD);
  }

  function test_work_auction_surplus() public {
    uint256 _initialBalance = systemCoin.balanceOf(address(this));
    _workAuctionSurplus(address(this));

    assertEq(systemCoin.balanceOf(address(this)) - _initialBalance, JOB_REWARD);
  }

  function test_work_transfer_extra_surplus() public {
    vm.startPrank(deployer);
    accountingEngine.modifyParameters('surplusIsTransferred', abi.encode(1));
    accountingEngine.modifyParameters('extraSurplusReceiver', abi.encode(address(0x420)));
    vm.stopPrank();

    uint256 _initialBalance = systemCoin.balanceOf(address(this));
    _workTransferExtraSurplus(address(this));

    assertEq(systemCoin.balanceOf(address(this)) - _initialBalance, JOB_REWARD);
  }

  function test_work_liquidation() public {
    uint256 _initialBalance = systemCoin.balanceOf(address(this));
    _workLiquidation(address(this), ETH_A, alice);

    assertEq(systemCoin.balanceOf(address(this)) - _initialBalance, JOB_REWARD);
  }

  function test_work_update_collateral_price() public {
    uint256 _initialBalance = systemCoin.balanceOf(address(this));
    _workUpdateCollateralPrice(address(this), ETH_A);

    assertEq(systemCoin.balanceOf(address(this)) - _initialBalance, JOB_REWARD);
  }

  function test_work_update_rate() public {
    uint256 _initialBalance = systemCoin.balanceOf(address(this));
    _workUpdateRate(address(this));

    assertEq(systemCoin.balanceOf(address(this)) - _initialBalance, JOB_REWARD);
  }
}

// --- Scoped test contracts ---

contract E2EJobsTestDirectUser is DirectUser, E2EJobsTest {}

contract E2EJobsTestProxyUser is ProxyUser, E2EJobsTest {}
