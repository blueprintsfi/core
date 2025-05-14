// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager, zero, oneOpArray} from "../BasicBlueprint.sol";
import {IOracle} from "./oracle/IOracle.sol";

struct Constraint {
	bytes32 feedId;
	uint256 startRange;
	uint256 endRange;
}

struct TokenParams {
	uint256 tokenId;
	Constraint[] constraints;
}

contract ComposablePredictionBlueprint is BasicBlueprint {
	IOracle immutable constantOracle;

	constructor(IBlueprintManager _manager, IOracle oracle) BasicBlueprint(_manager) {
		constantOracle = oracle;
	}

	function executeAction(bytes calldata action) external view returns (
		uint256,
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		TokenParams calldata params;
		assembly ("memory-safe") {
			params := add(action.offset, calldataload(action.offset))
		}
		(uint256 count, bytes32 mergeFeed, uint256 cut, uint256 end, bool merge, bool settle) =
			abi.decode(action[0x20:0xe0], (uint256, bytes32, uint256, uint256, bool, bool));

		TokenOp[] memory giveTake = zero();
		TokenOp[] memory initial = zero();
		TokenOp[] memory _final = new TokenOp[](2);

		uint256 collateralCount = count;
		uint256 idx;
		bool done = false;
		while (idx < params.constraints.length) {
			if (params.constraints[idx].feedId == mergeFeed) {
				require(!settle, "must not be settling");
				uint256 startRange = params.constraints[idx].startRange;
				uint256 endRange = params.constraints[idx].endRange;
				uint256 lastValue;
				unchecked {
					lastValue = endRange - 1;
				}
				// require(startRange <= lastValue);
				require(startRange < cut && cut <= lastValue, "invalid cut");
				require(startRange != endRange, "invalid range"); // for the case of 0, 0
				_final[0] = TokenOp(hashReplace(params, idx, startRange, cut), count);
				_final[1] = TokenOp(hashReplace(params, idx, cut, endRange), count);
				done = true;
				break;
			} else if (params.constraints[idx].feedId > mergeFeed)
				break;

			idx++;
		}

		if (!done) {
			if (!settle) {
				require(cut != 0, "cut must be nonzero");
				_final[0] = TokenOp(hashAdd(params, idx, mergeFeed, 0, cut), count);
				_final[1] = TokenOp(hashAdd(params, idx, mergeFeed, cut, 0), count);
			} else {
				uint256 lastValue;
				unchecked {
					lastValue = end - 1;
				}

				uint256 reading = constantOracle.getReading(mergeFeed, "");
				if (reading < cut || reading > lastValue)
					collateralCount = 0;
				_final = oneOpArray(hashAdd(params, idx, mergeFeed, cut, end), count);
			}
		}

		if (params.constraints.length == 0)
			giveTake = oneOpArray(params.tokenId, collateralCount);
		else
			initial = oneOpArray(hash(params), collateralCount); // todo: hash straight from calldata

		return merge ?
			(0, initial, _final, giveTake, zero()) :
			(0, _final, initial, zero(), giveTake);
	}

	function hash(TokenParams calldata params) internal pure returns (uint256 result) {
		uint256 tokenId = params.tokenId;
		Constraint[] calldata constraints = params.constraints;
		assembly ("memory-safe") {
			let ptr := mload(0x40)
			let len := mul(0x60, constraints.length)
			mstore(ptr, tokenId)
			calldatacopy(add(0x20, ptr), constraints.offset, len)
			result := keccak256(ptr, add(0x20, len))
		}
	}

	function hashAdd(
		TokenParams calldata params,
		uint256 idx,
		bytes32 feedId,
		uint256 start,
		uint256 end
	) internal pure returns (uint256 result) {
		uint256 tokenId = params.tokenId;
		Constraint[] calldata constraints = params.constraints;
		assembly ("memory-safe") {
			let ptr := mload(0x40)
			let len := mul(0x60, constraints.length)
			let preLen := mul(0x60, idx)
			let postLen := sub(len, preLen)
			let arrayPtr := add(0x20, ptr)
			mstore(ptr, tokenId)
			calldatacopy(arrayPtr, constraints.offset, preLen)
			arrayPtr := add(arrayPtr, preLen)
			mstore(arrayPtr, feedId)
			mstore(add(arrayPtr, 0x20), start)
			mstore(add(arrayPtr, 0x40), end)
			calldatacopy(add(arrayPtr, 0x60), add(constraints.offset, preLen), postLen)
			result := keccak256(ptr, add(0x80, len))
		}
	}

	function hashReplace(
		TokenParams calldata params,
		uint256 idx,
		uint256 start,
		uint256 end
	) internal pure returns (uint256 result) {
		uint256 tokenId = params.tokenId;
		Constraint[] calldata constraints = params.constraints;
		assembly ("memory-safe") {
			let ptr := mload(0x40)
			let len := mul(0x60, constraints.length)
			mstore(ptr, tokenId)
			let dataPtr := add(0x20, ptr)
			calldatacopy(dataPtr, constraints.offset, len)
			dataPtr := add(dataPtr, mul(0x60, idx))
			mstore(add(dataPtr, 0x20), start)
			mstore(add(dataPtr, 0x40), end)
			result := keccak256(ptr, add(0x20, len))
		}
	}
}
