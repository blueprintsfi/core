// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager, zero, oneOpArray} from "../BasicBlueprint.sol";
import {gcd} from "../../libraries/Math.sol";
import {IOracle} from "./oracle/IOracle.sol";

struct Range {
	int256 slope;
	uint256 length;
}

struct Payoff {
	uint256 init_value;
	Range[] pieces;
}

struct Constraint {
	bytes32 feed_id;
	bytes32 payoff_hash;
}

error InputPayoffHasRedundantRanges();
error InputPayoffHasTerminalZeroSlope();
error InputHasZeroLengthRange();
error InputIsConstantPayoff();
error ConstraintsNotSortedOrUnique();
error ZeroFeedId();

function hashPayoff(Payoff memory p) pure returns (bytes32) {
	return keccak256(abi.encode(p));
}

function tokenId(
	Constraint[] memory constraints,
	uint256 underlying_token_id
) pure returns (uint256) {
	return uint256(keccak256(abi.encode(constraints, underlying_token_id)));
}

function addConstraint(
	Constraint[] memory constraints,
	bytes32 feed_id,
	bytes32 payoff_hash
) pure returns (Constraint[] memory res, uint256 index) {
	if (feed_id == 0) {
		revert ZeroFeedId();
	}
	res = new Constraint[](constraints.length + 1);
	uint256 i = 0;
	bytes32 previous_feed = bytes32(0);
	while (i < constraints.length) {
		bytes32 feed = constraints[i].feed_id;
		if (feed >= feed_id) {
			break;
		}

		if (feed <= previous_feed) {
			revert ConstraintsNotSortedOrUnique();
		}
		previous_feed = feed;

		res[i] = constraints[i];
		unchecked { i++; }
	}

	res[i] = Constraint({ feed_id: feed_id, payoff_hash: payoff_hash });
	index = i;
	previous_feed = feed_id;

	while (i < constraints.length) {
		bytes32 feed = constraints[i].feed_id;
		if (feed <= previous_feed) {
			revert ConstraintsNotSortedOrUnique();
		}
		previous_feed = feed;

		res[i + 1] = constraints[i];
		unchecked { i++; }
	}
}

function muladd(uint256 acc, uint256 a, int256 b) pure returns (uint256) {
	if (b < 0) {
		uint256 abs_b;
		unchecked { abs_b = uint256(-b); }
		return acc - a * abs_b;
	}
	return acc + a * uint256(b);
}

function add(
	Payoff memory p0,
	Payoff memory p1
) pure returns (Payoff memory res) {
	res.init_value = p0.init_value + p1.init_value;

	if (p1.pieces.length == 0) {
		if (p0.pieces.length == 0) {
			return res;
		} else {
			// p1 number of pieces must be nonzero
			(p0, p1) = (p1, p0);
		}
	}
	uint256 res_index = 0;
	res.pieces = new Range[](p0.pieces.length + p1.pieces.length);

	uint256 p0_index = 0;
	uint256 p1_index = 1;
	uint256 p1_remaining = p1.pieces[0].length;
	int256 p1_slope = p1.pieces[0].slope;

	// loop invariant: p0_remaining == 0
	while (p0_index < p0.pieces.length) {
		uint256 p0_remaining = p0.pieces[p0_index].length;
		int256 p0_slope = p0.pieces[p0_index].slope;
		p0_index++;

		if (p0_remaining > p1_remaining) {
			(p0, p1) = (p1, p0);
			(p0_index, p1_index) = (p1_index, p0_index);
			(p0_slope, p1_slope) = (p1_slope, p0_slope);
			(p0_remaining, p1_remaining) = (p1_remaining, p0_remaining);
		}

		// skip overflow checks and short-circuit
		if (p0_remaining == 0)
			continue;

		int256 res_slope = p0_slope + p1_slope;
		res_index = appendElement(res, res_index, res_slope, p0_remaining);

		unchecked { p1_remaining -= p0_remaining; }
	}

	res_index = appendElement(res, res_index, p1_slope, p1_remaining);

	while (p1_index < p1.pieces.length) {
		Range memory r = p1.pieces[p1_index];
		res_index = appendElement(res, res_index, r.slope, r.length);
		p1_index++;
	}

	Range[] memory pieces = res.pieces;
	// we merge all but the last ranges, so this has to be done manually
	if (pieces[res_index - 1].slope == 0) {
		unchecked { res_index -= 1; }
	}
	assembly ("memory-safe") {
		mstore(pieces, res_index)
	}
}

function checkAndNormalizePayoff(Payoff memory p) pure returns (uint256 divisor) {
	divisor = p.init_value;
	Range[] memory pieces = p.pieces;
	int256 prev_slope;
	uint256 value = p.init_value;
	uint256 x = 0;
	for (uint256 i = 0; i < pieces.length; i++) {
		int256 slope = pieces[i].slope;
		uint256 length = pieces[i].length;
		if (i != 0 && prev_slope == slope)
			revert InputPayoffHasRedundantRanges();
		if (length == 0)
			revert InputHasZeroLengthRange();
		prev_slope = slope;
		x += length;
		value = muladd(value, length, slope);
		unchecked {
			// calculate the absolute value, inspired by OpenZeppelin
			int256 mask = slope >> 255;
			uint256 abs_slope = uint256((slope + mask) ^ mask);
			divisor = gcd(divisor, abs_slope);
		}
	}

	if (pieces.length > 0 && pieces[pieces.length - 1].slope == 0) {
		revert InputPayoffHasTerminalZeroSlope();
	}

	// divisor can't be zero, since the whole sum of payoffs would need to
	// be zero; payoffs are nonnegative, it would mean the addends are also
	// zero. Adding zero payoffs isn't needed, hence it's ok to revert here.
	p.init_value /= divisor;
	for (uint256 i = 0; i < pieces.length; i++) {
		// If all slopes are zero or type(int256).min and the init_value is
		// 0 or 2**255, parsing divisor as an int256 may overflow. In that
		// case, we want to divide by 2**255, not the negative counterpart.
		// Else, divide normally. Note that if the divisor is larger than
		// 2**255, then all slopes must be zero. int256(divisor) produces a
		// nonzero (negative) number. Dividing zero by a nonzero number
		// gives zero, the correct output when divided by divisor.
		if (int256(divisor) == type(int256).min) {
			// zero if it's zero, -1 if it's type(int256).min
			pieces[i].slope >>= 255;
		} else {
			pieces[i].slope /= int256(divisor);
		}
	}
}

function appendElement(
	Payoff memory res,
	uint256 idx,
	int256 slope,
	uint256 length
) pure returns (uint256 /* newidx */) {
	if (length == 0)
		return idx;
	if (idx != 0) {
		if (res.pieces[idx - 1].slope == slope) {
			res.pieces[idx - 1].length += length;
			return idx;
		}
	}
	res.pieces[idx].slope = slope;
	res.pieces[idx].length = length;
	return idx + 1;
}

function valueAt(Payoff memory p, uint256 x) pure returns (uint256) {
	uint256 current_value = p.init_value;
	for (uint256 i = 0; i < p.pieces.length; i++) {
		Range memory r = p.pieces[i];
		if (r.length >= x) {
			return muladd(current_value, x, r.slope);
		}
		current_value = muladd(current_value, r.length, r.slope);
		unchecked { x -= r.length; }
	}
	// the slope is zero after the last range, so returning is correct
	return current_value;
}

contract PredictionBlueprint is BasicBlueprint {
	IOracle immutable constantOracle;

	constructor(IBlueprintManager m, IOracle oracle) BasicBlueprint(m) {
		constantOracle = oracle;
	}

	function executeAction(bytes calldata action) external view returns (
		uint256 subaccount,
		TokenOp[] memory mint,
		TokenOp[] memory burn,
		TokenOp[] memory give,
		TokenOp[] memory take
	) {
		bool redeem;
		bool merge;
		uint256 underlying_token_id;
		bytes32 feed_id;
		Constraint[] memory other_constraints;
		Payoff memory p1;
		(redeem, merge, underlying_token_id, feed_id, other_constraints, p1) =
			abi.decode(action, (bool, bool, uint256, bytes32, Constraint[], Payoff));

		bool use_underlying = other_constraints.length == 0;
		uint256 underlying_or_collateral = use_underlying ?
			underlying_token_id :
			tokenId(other_constraints, underlying_token_id);

		TokenOp[] memory sum_gt = zero(); // give/take
		TokenOp[] memory addends_gt = zero();
		TokenOp[] memory sum_mb = zero(); // mint/burn
		TokenOp[] memory addends_mb = zero();

		if (redeem) {
			uint256 reading = constantOracle.getReading(feed_id);
			uint256 value = valueAt(p1, reading);

			if (use_underlying) {
				sum_gt = oneOpArray(underlying_or_collateral, value);
			} else {
				sum_mb = oneOpArray(underlying_or_collateral, value);
			}

			uint256 p1_count = checkAndNormalizePayoff(p1);
			if (p1.pieces.length == 0) {
				revert InputIsConstantPayoff();
			}
			(Constraint[] memory constraints,) = addConstraint(
				other_constraints,
				feed_id,
				hashPayoff(p1)
			);
			addends_mb = oneOpArray(tokenId(constraints, underlying_token_id), p1_count);
		} else {
			Payoff calldata p2_c;
			assembly ("memory-safe") {
				p2_c := add(action.offset, calldataload(add(action.offset, 192)))
			}
			Payoff memory p2 = p2_c;

			Payoff memory sum = add(p1, p2);

			uint256 p1_count = checkAndNormalizePayoff(p1);
			(Constraint[] memory constraints, uint256 index) = addConstraint(
				other_constraints,
				feed_id,
				hashPayoff(p1)
			);

			addends_mb = new TokenOp[](2);
			if (p1.pieces.length == 0) {
				revert InputIsConstantPayoff();
			}
			addends_mb[0] = TokenOp(tokenId(constraints, underlying_token_id), p1_count);

			uint256 p2_count = checkAndNormalizePayoff(p2);
			// allow p2 to be constant, unlike p1; means adding collateral
			if (p2.pieces.length == 0) {
				if (use_underlying) {
					addends_gt = oneOpArray(underlying_or_collateral, p2_count);
				} else {
					addends_mb[1] = TokenOp(underlying_or_collateral, p2_count);
				}
			} else {
				constraints[index].payoff_hash = hashPayoff(p2);
				addends_mb[1] = TokenOp(tokenId(constraints, underlying_token_id), p2_count);
			}

			uint256 sum_count = checkAndNormalizePayoff(sum);
			if (sum.pieces.length == 0) {
				if (use_underlying) {
					sum_gt = oneOpArray(underlying_token_id, sum_count);
				} else {
					sum_mb = oneOpArray(tokenId(other_constraints, underlying_token_id), sum_count);
				}
			} else {
				constraints[index].payoff_hash = hashPayoff(sum);
				sum_mb = oneOpArray(tokenId(constraints, underlying_token_id), sum_count);
			}
		}

		return merge ?
			(0, sum_mb, addends_mb, sum_gt, addends_gt) :
			(0, addends_mb, sum_mb, addends_gt, sum_gt);
	}
}
