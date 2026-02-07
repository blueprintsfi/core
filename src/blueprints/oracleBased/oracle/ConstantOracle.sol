// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IOracle} from "./IOracle.sol";
import {HashLib} from "../../../libraries/HashLib.sol";

struct Data {
	uint256 dataPlusOne;
	uint256 add;
}

struct Response {
	bytes32 feedId;
	uint256 data;
}

struct Resolution {
	address oracle;
	bytes32 feedId;
	bytes proof;
}

contract ConstantOracle is IOracle {
	function _cache(address oracle, bytes32 feedId, uint256 data) internal {
		Data storage reading;
		{
			uint256 slot = HashLib.hash(oracle, uint256(feedId));
			assembly { reading.slot := slot }
		}

		// if a value is already saved, pretend this succeeded
		if (reading.dataPlusOne != 0)
			return;

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

	function cache(Response[] calldata responses) external {
		for (uint256 i = 0; i < responses.length; i++) {
			Response calldata response = responses[i];
			_cache(msg.sender, response.feedId, response.data);
		}
	}

	function cache(address oracle, bytes32 feedId, bytes calldata proof) public returns (uint256 data) {
		data = IOracle(oracle).getReading(feedId, proof);
		_cache(oracle, feedId, data);
	}

	function cache(Resolution[] calldata resolutions) external {
		for (uint256 i = 0; i < resolutions.length; i++) {
			Resolution calldata res = resolutions[i];
			cache(res.oracle, res.feedId, res.proof);
		}
	}

	function getReading(bytes32 feedId, bytes calldata proof) external returns (uint256 data) {
		if (proof.length < 52)
			revert InvalidProof();

		address oracle = address(bytes20(proof));
		bytes32 internalFeedId = bytes32(proof[20:]);

		if (bytes32(HashLib.hash(oracle, uint256(internalFeedId))) != feedId)
			revert InvalidProof();

		return cache(oracle, internalFeedId, proof[52:]);
	}

	function getReading(bytes32 feedId) public view returns (uint256 data) {
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
