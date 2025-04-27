// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IOracle} from "./IOracle.sol";

struct Data {
	uint256 dataPlusOne;
	uint256 add;
}

contract ConstantOracle is IOracle {
	function _cache(address oracle, bytes32 feedId, uint256 data) internal {
		Data storage reading;
		assembly ("memory-safe") {
			mstore(0, oracle)
			mstore(0x20, feedId)
			reading.slot := keccak256(12, 52)
		}
		require(reading.dataPlusOne == 0);
		unchecked {
			if (data == type(uint256).max) {
				reading.dataPlusOne = data;
				reading.add = 1;
			} else
				reading.dataPlusOne = data + 1;
		}
	}

	function cache(bytes32 feedId, uint256 data) external {
		_cache(msg.sender, feedId, data);
	}

	function cache(address oracle, bytes32 feedId, bytes calldata proof) external returns (uint256 data) {
		data = IOracle(oracle).getReading(feedId, proof);
		_cache(oracle, feedId, data);
	}

	function getReading(bytes32 feedId, bytes calldata) external view returns (uint256 data) {
		Data storage reading;
		assembly ("memory-safe") {
			reading.slot := feedId
		}
		data = reading.dataPlusOne;
		require(data != 0, "Reading not cached yet");
		unchecked {
			if (data-- == type(uint256).max)
				data += reading.add;
		}
	}
}
