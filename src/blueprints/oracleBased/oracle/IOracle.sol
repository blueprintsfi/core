// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IOracle {
	function getReading(bytes32 feedId, bytes calldata proof) external view returns (uint256 data);
}
