// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IOracle} from "./IOracle.sol";

contract SimplifyOracle is IOracle {
	function getReading(bytes32 feedId, bytes calldata proof) external returns (uint256 data) {
		require(keccak256(proof[:52]) == feedId);
		address oracle = address(bytes20(proof));
		bytes32 internalFeedId = bytes32(proof[20:]);
		return IOracle(oracle).getReading(internalFeedId, proof[52:]);
	}

	function getReading(bytes32) external pure returns (uint256) {
		revert();
	}
}
