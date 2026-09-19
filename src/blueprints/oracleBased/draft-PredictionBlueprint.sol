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

function hashPayoff(Payoff memory p) pure returns (bytes32) {
	// todo: encodePacked
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
	res = new Constraint[](constraints.length + 1);
	uint256 i = 0;
	while (i < constraints.length) {
		if (feed_id < constraints[i].feed_id) {
			break;
		}
		res[i] = constraints[i];
		unchecked { i++; }
	}

	res[i] = Constraint({ feed_id: feed_id, payoff_hash: payoff_hash });
	index = i;

	while (i < constraints.length) {
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
	uint256 current_value = p0.init_value + p1.init_value;
	res.init_value = current_value;

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
	// we monitor values to make sure they don't underflow
	uint256 p0_value = p0.init_value;
	uint256 p1_value = p1.init_value;
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
			(p0_value, p1_value) = (p1_value, p0_value);
			(p0_slope, p1_slope) = (p1_slope, p0_slope);
			(p0_remaining, p1_remaining) = (p1_remaining, p0_remaining);
		}

		// if must be outside of the invocation in case the sum overflows
		if (p0_remaining != 0)
			res_index = appendElement(res, res_index, p0_slope + p1_slope, p0_remaining);

		unchecked { p1_remaining -= p0_remaining; }

		// res will not underflow since p0 and p1 do not underflow
		// res may overflow – it is caller's responsibility to prevent it
		p0_value = muladd(p0_value, p0_remaining, p0_slope);
		p1_value = muladd(p1_value, p0_remaining, p1_slope);
	}

	if (p1_remaining != 0)
		res_index = appendElement(res, res_index, p1_slope, p1_remaining);

	// do not add p0_value since we want to validate p1 nonnegativity now
	p1_value = muladd(p1_value, p1_remaining, p1_slope);

	while (p1_index < p1.pieces.length) {
		Range memory r = p1.pieces[p1_index];
		if (r.length != 0)
			res_index = appendElement(res, res_index, r.slope, r.length);
		p1_value = muladd(
			p1_value,
			p1.pieces[p1_index].length,
			p1.pieces[p1_index].slope
		);
		p1_index++;
	}

	Range[] memory pieces = res.pieces;
	assembly ("memory-safe") {
		mstore(pieces, res_index)
	}
}

function normalizePayoff(Payoff memory p) pure returns (uint256) {
		uint256 divisor = p.init_value;
		for (uint256 i = 0; i < p.pieces.length; i++) {
			int256 slope = p.pieces[i].slope;
			unchecked {
				// calculate the absolute value, inspired by OpenZeppelin
				int256 mask = slope >> 255;
				uint256 abs_slope = uint256((slope + mask) ^ mask);
				divisor = gcd(divisor, abs_slope);
			}
		}

		// divisor can't be zero, since the whole sum of payoffs would need to
		// be zero; payoffs are nonnegative, it would mean the addends are also
		// zero. Adding zero payoffs isn't needed, hence it's ok to revert here.
		p.init_value /= divisor;
		for (uint256 i = 0; i < p.pieces.length; i++) {
			// If all slopes are zero or type(int256).min and the init_value is
			// 0 or 2**255, parsing divisor as an int256 may overflow. In that
			// case, we want to divide by 2**255, not the negative counterpart.
			// Else, divide normally. Note that if the divisor is larger than
			// 2**255, then all slopes must be zero. int256(divisor) produces a
			// nonzero (negative) number. Dividing zero by a nonzero number
			// gives zero, the correct output when divided by divisor.
			if (int256(divisor) == type(int256).min) {
				// zero if it's zero, -1 if it's type(int256).min
				p.pieces[i].slope >>= 255;
			} else {
				p.pieces[i].slope /= int256(divisor);
			}
		}

		// we merge all but the first ranges, so this has to be done manually
		if (p.pieces.length == 1 && p.pieces[0].slope == 0) {
			p.pieces = new Range[](0);
		}

		return divisor;
	}

	function appendElement(
		Payoff memory res,
		uint256 idx,
		int256 slope,
		uint256 length
	) pure returns (uint256 /* newidx */) {
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
		(redeem, merge, underlying_token_id, feed_id) =
			abi.decode(action[:128], (bool, bool, uint256, bytes32));

		TokenOp[] memory underlying = zero();
		TokenOp[] memory collateral = zero();
		TokenOp[] memory created = zero();

		if (redeem) {
			(other_constraints, p1) =
				abi.decode(action[128:], (Constraint[], Payoff));

			uint256 reading = constantOracle.getReading(feed_id);
			uint256 value = valueAt(p1, reading);

			if (other_constraints.length == 0) {
				underlying = oneOpArray(underlying_token_id, value);
			} else {
				collateral = oneOpArray(tokenId(other_constraints, underlying_token_id), value);
			}

			uint256 p1_count = normalizePayoff(p1);
			(Constraint[] memory constraints,) = addConstraint(
				other_constraints,
				feed_id,
				hashPayoff(p1)
			);
			created = oneOpArray(tokenId(constraints, underlying_token_id), p1_count);
		} else {
			Payoff memory p2;
			(other_constraints, p1, p2) =
				abi.decode(action[128:], (Constraint[], Payoff, Payoff));

			Payoff memory sum = add(p1, p2);

			uint256 p1_count = normalizePayoff(p1);
			(Constraint[] memory constraints, uint256 index) = addConstraint(
				other_constraints,
				feed_id,
				hashPayoff(p1)
			);

			created = new TokenOp[](2);
			created[0] = TokenOp(tokenId(constraints, underlying_token_id), p1_count);
			uint256 p2_count = normalizePayoff(p2);
			constraints[index].payoff_hash = hashPayoff(p2);
			created[1] = TokenOp(tokenId(constraints, underlying_token_id), p2_count);

			uint256 sum_count = normalizePayoff(sum);
			uint256 len = sum.pieces.length;
			if (len == 0) {
				// this is the case when the payoff is constant
				if (other_constraints.length == 0) {
					underlying = oneOpArray(underlying_token_id, sum_count);
				} else {
					collateral = oneOpArray(tokenId(other_constraints, underlying_token_id), sum_count);
				}
			} else {
				constraints[index].payoff_hash = hashPayoff(sum);
				collateral = oneOpArray(tokenId(constraints, underlying_token_id), sum_count);
			}
		}

	    return merge ?
			(0, collateral, created, underlying, zero()) :
			(0, created, collateral, zero(), underlying);
	}
}
