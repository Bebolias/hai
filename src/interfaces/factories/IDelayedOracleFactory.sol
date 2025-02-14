// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IBaseOracle} from '@interfaces/oracles/IBaseOracle.sol';
import {IDelayedOracle} from '@interfaces/oracles/IDelayedOracle.sol';
import {IAuthorizable} from '@interfaces/utils/IAuthorizable.sol';

interface IDelayedOracleFactory is IAuthorizable {
  // --- Events ---
  event NewDelayedOracle(address indexed _delayedOracle, address _priceSource, uint256 _updateDelay);

  // --- Methods ---
  function deployDelayedOracle(
    IBaseOracle _priceSource,
    uint256 _updateDelay
  ) external returns (IDelayedOracle _delayedOracle);

  // --- Views ---
  function delayedOraclesList() external view returns (address[] memory _delayedOraclesList);
}
