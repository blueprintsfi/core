// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager, zero, oneOpArray} from "../BasicBlueprint.sol";
import {IOracle} from "./oracle/IOracle.sol";

struct TokenParams {
	uint256 tokenId;
	bytes32 feedId;
	uint256 startRange;
	uint256 endRange;
	int256 slope;
	uint256 offset;
	uint256 denominator;
}

enum Action {VerticalSplit, SlopeSplit, Settlement}

contract OracleBasedLinearBlueprint is BasicBlueprint {
	IOracle immutable constantOracle;

	constructor(IBlueprintManager _manager, IOracle oracle) BasicBlueprint(_manager) {
		constantOracle = oracle;
	}

	function executeAction(bytes calldata action) external onlyManager view returns (
		uint256,
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		TokenParams memory params;
		assembly ("memory-safe") {
			params := mload(0x40)
			calldatacopy(params, action.offset, 0xe0)
		}
		(uint256 count, uint256 arg, bool merge, Action x) =
			abi.decode(action[0xe0:], (uint256, uint256, bool, Action));
		bool full = (params.endRange | params.startRange) == 0;
		require(full || params.startRange < params.endRange);
		uint256 lastValue;
		unchecked {
			lastValue = params.endRange - 1;
		}

		TokenOp[] memory giveTake = zero();
		TokenOp[] memory initial = zero();
		TokenOp[] memory _final = new TokenOp[](2);

		if (x == Action.SlopeSplit) { // arg is total collateral per token
			// we split the value: turn a constant function on an interval to two slopes on the same interval
			// current slope is 0
			// position we come from:
			// tokenId, feedId, startRange, endRange, 0, 1, 1                   times count * total
			// positions we create:
			// tokenId, feedId, startRange, endRange, slope, offset, denominator      times count
			// tokenId, feedId, startRange, endRange, -slope, ***, denominator      times count
			// the sign is only a signal of the other side of the position
			require(params.slope >= 0);
			require(params.offset < arg * params.denominator); // note: already checked by an underflow check below
			if (params.slope < 0)
				require(valueAt(params, lastValue, lastValue) <= arg);

			_final[0] = TokenOp(getId(params), count);
			params.slope = -params.slope; // reverts if slope is too small
			params.offset = arg * params.denominator - params.offset; // reverts if collateral is too low

			_final[1] = TokenOp(getId(params), count);

			if (full) {
				giveTake = oneOpArray(params.tokenId, count * arg);
			} else {
				params.slope = 0;
				params.offset = 1;
				params.denominator = 1;
				initial = oneOpArray(getId(params), count * arg);
			}
		} else if (x == Action.VerticalSplit) { // vertical split x value is arg
			// vertical split:
			// having function f and the split argument z, we create two derivatives:
			// g(r) = r < z ? 0 : f(r)
			// h(r) = r < z ? f(r) : 0

			// we do a vertical split with arg SPLIT:
			// position we come from:
			// tokenId, feedId, startRange, endRange, slope, offset, denominator    times count
			// positions we create:
			// tokenId, feedId, startRange, SPLIT, slope, offset, denominator      times count
			// tokenId, feedId, SPLIT, endRange, slope, offset + (SPLIT - startRange) * slope, denominator   times count

			if (full && params.slope == 0 && params.offset == 1 && params.denominator == 1)
				giveTake = oneOpArray(params.tokenId, count);
			else
				initial = oneOpArray(getId(params), count);
			uint256 endRange = params.endRange;
			uint256 startRange = params.startRange;
			require(startRange < arg && arg <= lastValue);

			params.endRange = arg;
			_final[0] = TokenOp(getId(params), count);

			params.startRange = arg;
			params.endRange = endRange;
			if (params.slope < 0)
				params.offset -= (arg - startRange) * uint256(-params.slope);
			else
				params.offset += (arg - startRange) * uint256(params.slope);
			_final[1] = TokenOp(getId(params), count);
		} else {
			uint256 value = valueAt(params, constantOracle.getReading(params.feedId, ""), lastValue);
			giveTake = oneOpArray(params.tokenId, count * value);
			_final = oneOpArray(getId(params), count);
		}

		return merge ?
			(0, initial, _final, giveTake, zero()) :
			(0, _final, initial, zero(), giveTake);
	}

	function getId(TokenParams memory params) public pure returns (uint256 hash) {
		assembly ("memory-safe") {
			hash := keccak256(params, 0xe0)
		}
	}

	function valueAt(TokenParams memory params, uint256 argument, uint256 lastValue) internal pure returns (uint256) {
		if (argument < params.startRange || argument > lastValue)
			return 0;

		uint256 argDelta = argument - params.startRange;
		if (params.slope < 0) {
			return (params.denominator - 1 + params.offset - uint256(-params.slope) * argDelta)
				/ params.denominator;
		}
		return (params.offset + uint256(params.slope) * argDelta) / params.denominator;
	}
}
