// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {HaiTest} from '@test/utils/HaiTest.t.sol';
import {HAI, HAI_INITIAL_PRICE, ETH_A} from '@script/Params.s.sol';
import {Deploy} from '@script/Deploy.s.sol';
import {TestParams, TKN, TEST_ETH_PRICE, TEST_TKN_PRICE} from '@test/e2e/TestParams.s.sol';
import {
  Contracts,
  ICollateralJoin,
  ERC20ForTest,
  ERC20ForTestnet,
  IERC20Metadata,
  OracleForTest,
  IBaseOracle,
  ISAFEEngine
} from '@script/Contracts.s.sol';
import {WETH9} from '@contracts/for-test/WETH9.sol';
import {Math, RAY} from '@libraries/Math.sol';

uint256 constant RAD_DELTA = 0.0001e45;
uint256 constant COLLATERAL_PRICE = 100e18;

uint256 constant COLLAT = 1e18;
uint256 constant DEBT = 500e18; // LVT 50%
uint256 constant TEST_ETH_PRICE_DROP = 100e18; // 1 ETH = 100 HAI

/**
 * @title  DeployForTest
 * @notice Contains the deployment initialization routine for test environments
 */
contract DeployForTest is TestParams, Deploy {
  constructor() {
    // NOTE: creates fork in order to have WETH at 0x4200000000000000000000000000000000000006
    vm.createSelectFork(vm.rpcUrl('mainnet'));
  }

  function setupEnvironment() public virtual override {
    WETH9 weth = WETH9(payable(0x4200000000000000000000000000000000000006));

    systemCoinOracle = new OracleForTest(HAI_INITIAL_PRICE); // 1 HAI = 1 USD
    delayedOracle[ETH_A] = new OracleForTest(TEST_ETH_PRICE); // 1 ETH = 2000 USD
    delayedOracle[TKN] = new OracleForTest(TEST_TKN_PRICE); // 1 TKN = 1 USD

    collateral[ETH_A] = IERC20Metadata(address(weth));
    collateral[TKN] = new ERC20ForTest();

    delayedOracle['TKN-A'] = new OracleForTest(COLLATERAL_PRICE);
    delayedOracle['TKN-B'] = new OracleForTest(COLLATERAL_PRICE);
    delayedOracle['TKN-C'] = new OracleForTest(COLLATERAL_PRICE);
    delayedOracle['TKN-8D'] = new OracleForTest(COLLATERAL_PRICE);

    collateral['TKN-A'] = new ERC20ForTest();
    collateral['TKN-B'] = new ERC20ForTest();
    collateral['TKN-C'] = new ERC20ForTest();
    collateral['TKN-8D'] = new ERC20ForTestnet('8 Decimals TKN', 'TKN', 8);

    collateralTypes.push(ETH_A);
    collateralTypes.push(TKN);
    collateralTypes.push('TKN-A');
    collateralTypes.push('TKN-B');
    collateralTypes.push('TKN-C');
    collateralTypes.push('TKN-8D');

    _getEnvironmentParams();
  }
}

/**
 * @title  Common
 * @notice Abstract contract that contains for test methods, and triggers DeployForTest routine
 * @dev    Used to be inherited by different test contracts with different scopes
 */
abstract contract Common is DeployForTest, HaiTest {
  address alice = address(0x420);
  address bob = address(0x421);
  address carol = address(0x422);
  address dave = address(0x423);

  uint256 auctionId;

  function setUp() public virtual {
    run();

    for (uint256 i = 0; i < collateralTypes.length; i++) {
      bytes32 _cType = collateralTypes[i];
      taxCollector.taxSingle(_cType);
    }

    vm.label(deployer, 'Deployer');
    vm.label(alice, 'Alice');
    vm.label(bob, 'Bob');
    vm.label(carol, 'Carol');
    vm.label(dave, 'Dave');
  }

  function _setCollateralPrice(bytes32 _collateral, uint256 _price) internal {
    IBaseOracle _oracle = oracleRelayer.cParams(_collateral).oracle;
    vm.mockCall(
      address(_oracle), abi.encodeWithSelector(IBaseOracle.getResultWithValidity.selector), abi.encode(_price, true)
    );
    vm.mockCall(address(_oracle), abi.encodeWithSelector(IBaseOracle.read.selector), abi.encode(_price));
    oracleRelayer.updateCollateralPrice(_collateral);
  }

  function _collectFees(bytes32 _cType, uint256 _timeToWarp) internal {
    vm.warp(block.timestamp + _timeToWarp);
    taxCollector.taxSingle(_cType);
  }
}
