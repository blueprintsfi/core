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

	// This function has 4 utilities:
	//   - split conditional token across some oracle feed; can include a feed
	//     the token is independent of, or can split across a dependent feed
	//   - merge conditional tokens across an oracle feed; both need to be
	//     identical with respect to other constraints and the merge feed ranges
	//     have to be neighboring
	//   - settle conditional token with respect to some feed, reading the
	//     result and making the new token independent of that feed
	//   - invert settlement with respect to some feed – create a more
	//     constrained token for zero/full price, depending on an oracle reading
	//
	// Constraints are defined on ranges [a, b), where the full range is denoted
	// as [0, 0). Tokens must never have constraints on full range mentioned.
	// If such a constraint is created via merge, it is removed. Similarly,
	// settlement removes the constraint entirely.
	// The constraints are always sorted by the feedId of the constraint, from
	// smallest to largest.
	//
	// The token id is kecccak256(abi.encodePacked(tokenParams)), where
	// tokenParams is a struct of type TokenParams.
	//
	// A token with no constraints is the same as the underlying token – so, it
	// is used whenever creating a new conditional token and given back after
	// settling existing tokens with respect to all constraints.
	//
	// split(params, count, mergeFeed, cut, _end, merge=false, settle=false)
	//   takes `count` of token with TokenParams `params` and splits it across
	//   feed `mergeFeed`. With the initial `mergeFeed` constraints at [a, b),
	//   the two new tokens have constraints at [a, cut) and [cut, b),
	//   respectively. If `mergeFeed` has full range constraint, it shouldn't be
	//   in the constraint list and a new constraint is added.
	// merge(params, count, mergeFeed, cut, _end, merge=true, settle=false)
	//   creates `count` of token with TokenParams `params` by merging them by
	//   `mergeFeed`. With the final `mergeFeed` constraints at [a, b), the two
	//   old (consumed) tokens have constraints at [a, cut) and [cut, b),
	//   respectively. If `mergeFeed` is being removed (merged to full range),
	//   it shouldn't be in the constraint list of `params`.
	// settle(params, count, mergeFeed, cut, end, merge=true, settle=true)
	//   settles `count` of tokens `params` with an added constraint of feed
	//   `mergeFeed`, start `cut`, end `end`, to burn it if the oracle's
	//   response is out or range, or return a token with params `params` if the
	//   oracle's response decided the constraint is in range
	// unsettle(params, count, mergeFeed, cut, end, merge=false, settle=true)
	//   reverses the settlemtn of `count` of tokens `params` with an added
	//   constraint of feed `mergeFeed`, start `cut`, end `end`, to create it
	//   for free if the oracle's response is out or range, or take a token with
	//   params `params` if the response decided the constraint is in range
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
				// the following check is implied by the next one, so commented out
				// require(startRange <= lastValue);
				// make sure that the cut is at a valid position within the range
				require(startRange < cut && cut <= lastValue, "invalid cut");
				// startRange = endrange = 0 implies full range, which means that
				// it shouldn't have been mentioned in the sontraints, so revert
				require(startRange != endRange, "invalid range");
				// derive final tokens by replacing the respective ranges with
				// newer, more constrained ones
				_final[0] = TokenOp(hashReplace(params, idx, startRange, cut), count);
				_final[1] = TokenOp(hashReplace(params, idx, cut, endRange), count);

				done = true;
				break;
			} else if (params.constraints[idx].feedId > mergeFeed)
				break;

			idx++;
		}

		// if constraint isn't mentioned, meaning that it's full range…
		if (!done) {
			if (settle) {
				uint256 lastValue;
				unchecked {
					lastValue = end - 1;
				}

				uint256 reading = constantOracle.getReading(mergeFeed, "");
				if (reading < cut || reading > lastValue)
					collateralCount = 0;
				_final = oneOpArray(hashAdd(params, idx, mergeFeed, cut, end), count);
			} else {
				// if we're merging (or splitting), derive final (initial) tokenIds
				require(cut != 0, "cut must be nonzero");
				_final[0] = TokenOp(hashAdd(params, idx, mergeFeed, 0, cut), count);
				_final[1] = TokenOp(hashAdd(params, idx, mergeFeed, cut, 0), count);
			}
		}

		if (params.constraints.length == 0)
			giveTake = oneOpArray(params.tokenId, collateralCount);
		else
			initial = oneOpArray(hash(params), collateralCount);

		return merge ?
			(0, initial, _final, giveTake, zero()) :
			(0, _final, initial, zero(), giveTake);
	}

	// hashes TokenParams straight from calldata
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

	// hashes params with an added constraint at `idx`; the constraint is of
	// feed `feedId` and on range [`start`, `end`)
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

	// hashes params with the constraint at `idx` set to range [`start`, `end`)
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
