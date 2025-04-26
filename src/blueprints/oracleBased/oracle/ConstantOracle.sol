// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IOracle} from "./IOracle.sol";

struct Data {
	uint256 dataPlusOne;
	uint256 add;
}

contract ConstantOracle is IOracle {
	function cache(address oracle, bytes32 feedId, bytes calldata proof) external returns (uint256 data) {
		Data storage reading;
		assembly ("memory-safe") {
			mstore(0, oracle)
			mstore(0x20, feedId)
			reading.slot := keccak256(12, 52)
		}
		require(reading.dataPlusOne == 0);
		data = IOracle(oracle).getReading(feedId, proof);
		unchecked {
			if (data == type(uint256).max) {
				reading.dataPlusOne = data;
				reading.add = 1;
			} else
				reading.dataPlusOne = data + 1;
		}
	}

	function getReading(bytes32 feedId, bytes calldata) external view returns (uint256 data) {
		Data storage reading;
		assembly ("memory-safe") {
			reading.slot := feedId
		}
		uint256 value = reading.dataPlusOne;
		require(value != 0, "Reading not cached yet");
		unchecked {
			if (value-- == type(uint256).max)
				data = value + reading.add;
			else
				data = value;
		}
	}
}
