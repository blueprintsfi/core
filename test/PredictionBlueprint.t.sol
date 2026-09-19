// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// File authored by GPT 5.*

import {Test, stdError} from "forge-std/Test.sol";
import {BlueprintManager, BlueprintCall, HashLib} from "../src/BlueprintManager.sol";
import {TokenOp} from "../src/interfaces/IBlueprintManager.sol";
import { AccountingLib } from "../src/libraries/AccountingLib.sol";
import {ConstantOracle} from "../src/blueprints/oracleBased/oracle/ConstantOracle.sol";
import { PredictionBlueprint, Payoff, Range, Constraint, add, muladd, valueAt,
normalizePayoff, hashPayoff, tokenId, addConstraint } from
"../src/blueprints/oracleBased/draft-PredictionBlueprint.sol";

// External boundaries let the tests distinguish a checked revert from a wrong result.
contract PredictionBlueprintPayoffHarness {
	function evaluate(Payoff memory p, uint256 x) external pure returns (uint256) {
		return valueAt(p, x);
	}

	function sum(Payoff memory a, Payoff memory b) external pure returns (Payoff memory) {
		return add(a, b);
	}

	function normalize(Payoff memory p) external pure returns (uint256 count, Payoff memory) {
		count = normalizePayoff(p);
		return (count, p);
	}

	function multiplyAdd(uint256 acc, uint256 a, int256 b) external pure returns (uint256) {
		return muladd(acc, a, b);
	}
}

abstract contract PredictionTestBase is Test {
	uint256 internal constant MAX_PIECES = 12;

	function _copy(Payoff memory p) internal pure returns (Payoff memory) {
		return abi.decode(abi.encode(p), (Payoff));
	}

	function _constant(uint256 amount) internal pure returns (Payoff memory) {
		return Payoff(amount, new Range[](0));
	}

	function _line(
		uint256 initial,
		int256 slope,
		uint256 length
	) internal pure returns (Payoff memory p) {
		p = Payoff(initial, new Range[](1));
		p.pieces[0] = Range(slope, length);
	}

	function _abs(int256 a) internal pure returns (uint256) {
		unchecked { return uint256(a < 0 ? -a : a); }
	}

	// Preflight inequalities model checked uint256 arithmetic without calling muladd.
	function _referenceMuladd(
		uint256 acc,
		uint256 a,
		int256 b
	) internal pure returns (bool ok, uint256 result) {
		uint256 magnitude = _abs(b);
		if (magnitude != 0 && a > type(uint256).max / magnitude)
			return (false, 0);
		uint256 product = a * magnitude;
		if (b < 0) {
			if (product > acc)
				return (false, 0);
			return (true, acc - product);
		}
		if (product > type(uint256).max - acc)
			return (false, 0);
		return (true, acc + product);
	}

	function _referenceValue(
		Payoff memory p,
		uint256 x
	) internal pure returns (bool ok, uint256 result) {
		result = p.init_value;
		for (uint256 i; i < p.pieces.length; i++) {
			uint256 distance = x < p.pieces[i].length ? x : p.pieces[i].length;
			(ok, result) = _referenceMuladd(result, distance, p.pieces[i].slope);
			if (!ok)
				return (false, 0);
			if (distance == x)
				return (true, result);
			x -= distance;
		}
		return (true, result);
	}

	function _value(Payoff memory p, uint256 x) internal pure returns (uint256 result) {
		(bool ok, uint256 v) = _referenceValue(p, x);
		require(ok, "invalid reference input");
		return v;
	}

	// Construct nonnegative paths rather than discarding almost every random input.
	// Independent array inputs exercise unequal partitions, zero lengths, and both tails.
	function _valid(uint256 seed, Range[] memory raw) internal pure returns (Payoff memory p) {
		uint256 n = raw.length < MAX_PIECES ? raw.length : MAX_PIECES;
		p = Payoff(0, new Range[](n));
		int256 level;
		int256 minimum;
		int256 maximum;
		for (uint256 i; i < n; i++) {
			int256 slope = raw[i].slope % 101;
			uint256 length = raw[i].length % 17;
			p.pieces[i] = Range(slope, length);
			level += slope * int256(length);
			if (level < minimum)
				minimum = level;
			if (level > maximum)
				maximum = level;
		}
		// Half the seeds touch zero; retain nonzero constant payoffs for normalization.
		p.init_value = uint256(-minimum);
		if (seed % 2 != 0 || minimum == maximum)
			p.init_value += 1 + seed % 10000;
	}

	// Binary GCD is independent of the production Euclidean implementation.
	function _referenceGcd(uint256 a, uint256 b) internal pure returns (uint256) {
		if (a == 0)
			return b;
		if (b == 0)
			return a;
		uint256 shift;
		while (((a | b) & 1) == 0) {
			a >>= 1;
			b >>= 1;
			shift++;
		}
		while ((a & 1) == 0)
			a >>= 1;
		while (b != 0) {
			while ((b & 1) == 0)
				b >>= 1;
			if (a > b)
				(a, b) = (b, a);
			b -= a;
		}
		return a << shift;
	}

	function _referenceDivisor(Payoff memory p) internal pure returns (uint256 divisor) {
		divisor = p.init_value;
		for (uint256 i; i < p.pieces.length; i++)
			divisor = _referenceGcd(divisor, _abs(p.pieces[i].slope));
	}

	function _referenceNormalize(Payoff memory p) internal pure returns (uint256 count, Payoff memory q) {
		count = _referenceDivisor(p);
		q = _copy(p);
		q.init_value /= count;
		for (uint256 i; i < q.pieces.length; i++) {
			uint256 magnitude = _abs(p.pieces[i].slope) / count;
			q.pieces[i].slope = p.pieces[i].slope < 0 ? -int256(magnitude - 1) - 1 : int256(magnitude);
		}
		if (q.pieces.length == 1 && q.pieces[0].slope == 0)
			q.pieces = new Range[](0);
	}

	function _duration(Payoff memory p) internal pure returns (uint256 length) {
		for (uint256 i; i < p.pieces.length; i++)
			length += p.pieces[i].length;
	}

	// Only used with the short, small-coefficient payoffs from _valid.
	// Reconstruct slopes from adjacent values instead of reproducing add's range merge.
	function _referenceSum(Payoff memory p, Payoff memory q) internal pure returns (Payoff memory sum) {
		sum.init_value = p.init_value + q.init_value;
		uint256 duration = _duration(p);
		uint256 qDuration = _duration(q);
		if (qDuration > duration)
			duration = qDuration;
		sum.pieces = new Range[](duration);
		uint256 count;
		uint256 previous = sum.init_value;
		for (uint256 x; x < duration; x++) {
			uint256 next = _value(p, x + 1) + _value(q, x + 1);
			int256 slope = int256(next) - int256(previous);
			if (count != 0 && sum.pieces[count - 1].slope == slope)
				sum.pieces[count - 1].length++;
			else {
				sum.pieces[count] = Range(slope, 1);
				count++;
			}
			previous = next;
		}
		Range[] memory pieces = sum.pieces;
		assembly ("memory-safe") { mstore(pieces, count) }
	}

	function _reading(Payoff memory p, uint256 seed) internal pure returns (uint256) {
		uint256 mode = seed % 7;
		uint256 choice = seed / 7;
		if (mode == 0)
			return 0;
		if (mode == 1)
			return choice % (_duration(p) + 1);
		if (mode == 5)
			return type(uint256).max;
		if (mode == 6)
			return seed;
		uint256 knot;
		if (p.pieces.length != 0) {
			uint256 index = choice % p.pieces.length;
			for (uint256 i; i <= index; i++)
				knot += p.pieces[i].length;
		}
		if (mode == 3 && knot != 0)
			return knot - 1;
		if (mode == 4)
			return knot + 1;
		return knot;
	}

	function _scaled(Payoff memory p, uint256 scale) internal pure returns (Payoff memory q) {
		q = _copy(p);
		q.init_value *= scale;
		for (uint256 i; i < q.pieces.length; i++) {
			q.pieces[i].slope *= int256(scale);
		}
	}

	// Independent insertion model: preserve input order, including duplicate feeds.
	function _insert(
		Constraint[] memory c,
		bytes32 feed,
		bytes32 payoff
	) internal pure returns (Constraint[] memory out) {
		uint256 index;
		for (; index < c.length && c[index].feed_id <= feed; index++) {}
		out = new Constraint[](c.length + 1);
		for (uint256 i; i < out.length; i++) {
			if (i < index)
				out[i] = c[i];
			else if (i == index)
				out[i] = Constraint(feed, payoff);
			else
				out[i] = c[i - 1];
		}
	}

	function _id(Constraint[] memory c, uint256 underlying) internal pure returns (uint256) {
		return uint256(keccak256(abi.encode(c, underlying)));
	}

	function _claim(
		Constraint[] memory c,
		uint256 underlying,
		bytes32 feed,
		Payoff memory p
	) internal pure returns (uint256 id, uint256 amount) {
		(amount, p) = _referenceNormalize(p);
		id = _id(_insert(c, feed, keccak256(abi.encode(p))), underlying);
	}
}

contract PredictionBlueprintPayoffTest is PredictionTestBase {
	PredictionBlueprintPayoffHarness internal harness = new PredictionBlueprintPayoffHarness();

	function testFuzz_muladd(uint256 acc, uint256 a, int256 b) public {
		(bool expectedSuccess, uint256 expected) = _referenceMuladd(acc, a, b);
		(bool success, bytes memory data) = address(harness).call(
			abi.encodeCall(harness.multiplyAdd, (acc, a, b))
		);
		assertEq(success, expectedSuccess, "muladd success");
		if (success)
			assertEq(abi.decode(data, (uint256)), expected, "muladd value");
		else
			assertEq(data, stdError.arithmeticError, "muladd panic");
		assertEq(harness.multiplyAdd(acc, 0, b), acc);
		assertEq(harness.multiplyAdd(acc, a, 0), acc);
	}

	function testFuzz_valueAtRaw(Payoff memory p, uint256 x) public {
		// Unlike the valid-path generator, retain full-width coefficients and lengths.
		if (p.pieces.length > MAX_PIECES) {
			Range[] memory pieces = p.pieces;
			assembly ("memory-safe") { mstore(pieces, 12) }
		}
		_checkEvaluation(p, x);
		_checkEvaluation(p, 0);
		_checkEvaluation(p, type(uint256).max);
	}

	function _checkEvaluation(Payoff memory p, uint256 x) internal {
		(bool expectedSuccess, uint256 expected) = _referenceValue(p, x);
		(bool success, bytes memory data) = address(harness).call(
			abi.encodeCall(harness.evaluate, (p, x))
		);
		assertEq(success, expectedSuccess, "evaluation success");
		if (success)
			assertEq(abi.decode(data, (uint256)), expected, "evaluation value");
		else
			assertEq(data, stdError.arithmeticError, "evaluation panic");
	}

	function testFuzz_addConservesPayoffs(
		uint256 seed,
		Range[] memory a,
		Range[] memory b,
		uint256 x
	) public pure {
		Payoff memory p = _valid(seed, a);
		Payoff memory q = _valid(seed >> 128, b);
		bytes32 beforeP = keccak256(abi.encode(p));
		bytes32 beforeQ = keccak256(abi.encode(q));
		Payoff memory sum = add(p, q);
		Payoff memory reverse = add(q, p);
		assertEq(keccak256(abi.encode(p)), beforeP, "add mutated first input");
		assertEq(keccak256(abi.encode(q)), beforeQ, "add mutated second input");
		assertLe(sum.pieces.length, p.pieces.length + q.pieces.length);
		_checkSum(p, q, sum, reverse, 0);
		_checkSum(p, q, sum, reverse, x);
		_checkSum(p, q, sum, reverse, x % 193);
		_checkSum(p, q, sum, reverse, type(uint256).max);
		_checkBreakpoints(p, q, sum, reverse, p);
		_checkBreakpoints(p, q, sum, reverse, q);

		bytes32 beforeSum = keccak256(abi.encode(sum));
		bytes32 beforeReverse = keccak256(abi.encode(reverse));
		for (uint256 i; i < p.pieces.length; i++)
			p.pieces[i].slope++;
		for (uint256 i; i < q.pieces.length; i++)
			q.pieces[i].length++;
		assertEq(keccak256(abi.encode(sum)), beforeSum, "sum aliases operand");
		assertEq(keccak256(abi.encode(reverse)), beforeReverse, "reverse sum aliases operand");
	}

	function _checkSum(
		Payoff memory p,
		Payoff memory q,
		Payoff memory sum,
		Payoff memory reverse,
		uint256 x
	) internal pure {
		uint256 expected = _value(p, x) + _value(q, x);
		assertEq(valueAt(p, x), _value(p, x));
		assertEq(valueAt(q, x), _value(q, x));
		assertEq(valueAt(sum, x), expected, "pointwise sum");
		assertEq(valueAt(reverse, x), expected, "semantic commutativity");
	}

	function _checkBreakpoints(
		Payoff memory p,
		Payoff memory q,
		Payoff memory sum,
		Payoff memory reverse,
		Payoff memory knots
	) internal pure {
		uint256 x;
		for (uint256 i; i < knots.pieces.length; i++) {
			x += knots.pieces[i].length;
			_checkSum(p, q, sum, reverse, x);
			if (x != 0)
				_checkSum(p, q, sum, reverse, x - 1);
			_checkSum(p, q, sum, reverse, x + 1);
		}
	}

	function testFuzz_normalizeCoefficients(Payoff memory p) public {
		if (p.pieces.length > MAX_PIECES) {
			Range[] memory pieces = p.pieces;
			assembly ("memory-safe") { mstore(pieces, 12) }
		}
		uint256 divisor = _referenceDivisor(p);
		if (divisor == 0) {
			vm.expectRevert(stdError.divisionError);
			harness.normalize(p);
			return;
		}
		(uint256 count, Payoff memory normalized) = harness.normalize(p);
		assertEq(count, divisor, "normalization count");
		assertEq(normalized.init_value * count, p.init_value);
		bool removedFlat = p.pieces.length == 1 && p.pieces[0].slope == 0;
		assertEq(normalized.pieces.length, removedFlat ? 0 : p.pieces.length);
		for (uint256 i; i < normalized.pieces.length; i++) {
			assertEq(normalized.pieces[i].length, p.pieces[i].length);
			assertEq(_abs(normalized.pieces[i].slope) * count, _abs(p.pieces[i].slope));
			assertEq(normalized.pieces[i].slope < 0, p.pieces[i].slope < 0);
		}
		bytes32 before = keccak256(abi.encode(normalized));
		assertEq(normalizePayoff(normalized), 1, "normalization idempotent count");
		assertEq(keccak256(abi.encode(normalized)), before, "normalization idempotent payoff");
	}

	function testFuzz_normalizationPreservesValue(
		uint256 seed,
		Range[] memory ranges,
		uint256 x,
		uint32 scaleSeed
	) public pure {
		Payoff memory p = _valid(seed, ranges);
		Payoff memory scaled = _scaled(p, uint256(scaleSeed) + 1);
		Payoff memory original = _copy(p);
		uint256 count = normalizePayoff(p);
		uint256 scaledCount = normalizePayoff(scaled);
		assertEq(scaledCount, count * (uint256(scaleSeed) + 1));
		assertEq(keccak256(abi.encode(p)), keccak256(abi.encode(scaled)));
		assertEq(valueAt(p, x) * count, _value(original, x));
		assertEq(valueAt(p, x % 193) * count, _value(original, x % 193));
		assertEq(valueAt(p, 0) * count, original.init_value);
		assertEq(valueAt(p, type(uint256).max) * count, _value(original, type(uint256).max));
	}

	function test_addCopiesConstantOperand() public pure {
		Payoff memory p = _line(2, 2, 1);
		Payoff memory sum = add(p, _constant(1));
		assertEq(sum.init_value, 3);
		assertEq(sum.pieces[0].slope, 2);
		assertEq(normalizePayoff(p), 2);
		assertEq(sum.pieces[0].slope, 2, "normalizing input corrupted sum");
		p.pieces[0].length = 7;
		assertEq(sum.pieces[0].length, 1, "sum shares input range");
	}

	function test_addRemainingTail() public pure {
		Payoff memory p = Payoff(1, new Range[](2));
		p.pieces[0] = Range(1, 1);
		p.pieces[1] = Range(2, 1);
		Payoff memory sum = add(_constant(1), p);
		assertEq(sum.init_value, 2);
		assertEq(sum.pieces.length, 2);
		assertEq(sum.pieces[0].slope, 1);
		assertEq(sum.pieces[1].slope, 2);
		assertEq(valueAt(sum, 2), 5);
	}

	function test_addUnequalRangeLengths() public pure {
		Payoff memory sum = add(_line(0, 1, 2), _line(0, 2, 1));
		assertEq(valueAt(sum, 1), 3);
		assertEq(valueAt(sum, 2), 4, "short range was replayed after swap");
		assertEq(valueAt(sum, 3), 4);
	}

	function test_addComplementaryMultiPiecePayoffs() public pure {
		Payoff memory p = Payoff(0, new Range[](2));
		p.pieces[0] = Range(1, 1);
		p.pieces[1] = Range(-1, 1);
		Payoff memory q = Payoff(1, new Range[](2));
		q.pieces[0] = Range(-1, 1);
		q.pieces[1] = Range(1, 1);
		Payoff memory sum = add(p, q);
		assertEq(valueAt(sum, 0), 1);
		assertEq(valueAt(sum, 1), 1);
		assertEq(valueAt(sum, 2), 1);
		assertEq(valueAt(sum, type(uint256).max), 1);
	}

	function test_addIgnoresZeroLengthSlopeOverflow() public pure {
		Payoff memory sum = add(_line(1, type(int256).max, 0), _line(1, 1, 1));
		assertEq(valueAt(sum, 0), 2);
		assertEq(valueAt(sum, 1), 3);
	}

	function test_addRejectsInsolventTail() public {
		Payoff memory p = Payoff(1, new Range[](2));
		p.pieces[0] = Range(0, 1);
		p.pieces[1] = Range(-2, 1);
		vm.expectRevert(stdError.arithmeticError);
		harness.sum(_line(10, 0, 1), p);
	}

	function test_normalizationKnownCoefficientsAndClaim() public pure {
		Payoff memory p = Payoff(18, new Range[](2));
		p.pieces[0] = Range(6, 2);
		p.pieces[1] = Range(-12, 1);
		Payoff memory expected = Payoff(3, new Range[](2));
		expected.pieces[0] = Range(1, 2);
		expected.pieces[1] = Range(-2, 1);
		Constraint[] memory c = new Constraint[](1);
		c[0] = Constraint(bytes32(uint256(7)), keccak256(abi.encode(expected)));
		(uint256 id, uint256 count) = _claim(new Constraint[](0), 42, bytes32(uint256(7)), p);
		assertEq(count, 6);
		assertEq(id, uint256(keccak256(abi.encode(c, uint256(42)))));
		assertEq(normalizePayoff(p), 6);
		assertEq(abi.encode(p), abi.encode(expected));
	}

	function test_validGeneratorTouchesZeroAndRecovers() public pure {
		Range[] memory ranges = new Range[](2);
		ranges[0] = Range(-1, 2);
		ranges[1] = Range(2, 3);
		Payoff memory p = _valid(0, ranges);
		assertEq(p.init_value, 2);
		assertEq(valueAt(p, 1), 1);
		assertEq(valueAt(p, 2), 0);
		assertEq(valueAt(p, 3), 2);
		assertEq(valueAt(p, 5), 6);
	}

	function test_arithmeticExtremes() public pure {
		uint256 half = uint256(1) << 255;
		Payoff memory p = _line(half, type(int256).min, 1);
		assertEq(valueAt(p, 0), half);
		assertEq(valueAt(p, 1), 0);
		assertEq(valueAt(p, type(uint256).max), 0);
		assertEq(normalizePayoff(p), half);
		assertEq(p.init_value, 1);
		assertEq(p.pieces[0].slope, -1);
		p = _line(type(uint256).max, 0, type(uint256).max);
		assertEq(normalizePayoff(p), type(uint256).max);
		assertEq(p.init_value, 1);
		assertEq(valueAt(p, type(uint256).max), 1);
	}

	function test_addRejectsInsolventLeftOperandWithConstantRight() public {
		vm.expectRevert(stdError.arithmeticError);
		harness.sum(_line(0, -1, 1), _constant(10));
	}

	function test_addRejectsInsolventRightOperandWithConstantLeft() public {
		vm.expectRevert(stdError.arithmeticError);
		harness.sum(_constant(10), _line(0, -1, 1));
	}

	function test_addRejectsIntermediateDeficitBeforeRecovery() public {
		// A solvent sum and terminal value must not conceal an intermediate deficit.
		Payoff memory invalid = Payoff(1, new Range[](3));
		invalid.pieces[0] = Range(0, 1);
		invalid.pieces[1] = Range(-2, 1);
		invalid.pieces[2] = Range(2, 1);
		vm.expectRevert(stdError.arithmeticError);
		harness.sum(invalid, _line(10, 0, 1));
	}

	function test_addRejectsInitialValueOverflow() public {
		vm.expectRevert(stdError.arithmeticError);
		harness.sum(_constant(type(uint256).max), _constant(1));
	}

	function test_addRejectsNonzeroLengthSlopeOverflow() public {
		vm.expectRevert(stdError.arithmeticError);
		harness.sum(_line(0, type(int256).max, 1), _line(0, 1, 1));
	}

	function test_addRejectsComponentOverflowWithConstantRight() public {
		vm.expectRevert(stdError.arithmeticError);
		harness.sum(_line(type(uint256).max, 1, 1), _constant(0));
	}

	function test_normalizeRejectsZeroPayoff() public {
		vm.expectRevert(stdError.divisionError);
		harness.normalize(_constant(0));
	}

	function testFuzz_constraintAndHashBinding(
		Constraint[] memory c,
		bytes32 feed,
		bytes32 payoff,
		uint256 underlying
	) public pure {
		// No sorted/unique precondition: insertion must preserve even noncanonical inputs.
		bytes32 before = keccak256(abi.encode(c));
		(Constraint[] memory out, uint256 index) = addConstraint(c, feed, payoff);
		assertEq(keccak256(abi.encode(out)), keccak256(abi.encode(_insert(c, feed, payoff))));
		assertEq(keccak256(abi.encode(c)), before);
		assertEq(out.length, c.length + 1);
		assertEq(out[index].feed_id, feed);
		assertEq(out[index].payoff_hash, payoff);
		assertEq(tokenId(out, underlying), _id(out, underlying));
		assertNotEq(tokenId(out, underlying), tokenId(out, underlying ^ 1));
		uint256 id = tokenId(out, underlying);
		out[index].payoff_hash = bytes32(uint256(payoff) ^ 1);
		assertNotEq(tokenId(out, underlying), id);
		Payoff memory p = _line(underlying, int256(uint256(payoff)), uint256(feed));
		assertEq(hashPayoff(p), keccak256(abi.encode(p)));
	}
}

abstract contract PredictionBlueprintIntegrationBase is PredictionTestBase {
	BlueprintManager internal manager = new BlueprintManager();
	ConstantOracle internal oracle = new ConstantOracle();
	PredictionBlueprint internal prediction = new PredictionBlueprint(manager, oracle);

	struct Result {
		uint256 subaccount;
		TokenOp[] mint;
		TokenOp[] burn;
		TokenOp[] give;
		TokenOp[] take;
	}

	function _action(
		bool redeem,
		bool merge,
		uint256 underlying,
		bytes32 feed,
		Constraint[] memory c,
		Payoff memory p,
		Payoff memory q
	) internal pure returns (bytes memory) {
		// The blueprint decodes the header and dynamic payload separately.
		return bytes.concat(abi.encode(redeem, merge, underlying, feed),
			redeem ? abi.encode(c, p) : abi.encode(c, p, q));
	}

	function _result(bytes memory action) internal view returns (Result memory r) {
		(r.subaccount, r.mint, r.burn, r.give, r.take) = prediction.executeAction(action);
	}

	function _cook(bytes memory action) internal {
		BlueprintCall[] memory calls = new BlueprintCall[](1);
		calls[0] = BlueprintCall(address(this), 0, address(prediction), action, 0);
		manager.cook(address(this), calls);
	}

	function _op(TokenOp[] memory ops, uint256 index, uint256 id, uint256 amount) internal pure {
		assertEq(ops[index].tokenId, id, "operation token");
		assertEq(ops[index].amount, amount, "operation amount");
	}

	function _inverse(Result memory forward, Result memory backward) internal pure {
		assertEq(forward.subaccount, 0);
		assertEq(backward.subaccount, 0);
		assertEq(abi.encode(forward.mint), abi.encode(backward.burn));
		assertEq(abi.encode(forward.burn), abi.encode(backward.mint));
		assertEq(abi.encode(forward.give), abi.encode(backward.take));
		assertEq(abi.encode(forward.take), abi.encode(backward.give));
	}

	function _complement(Payoff memory p) internal pure returns (Payoff memory q, uint256 cap) {
		cap = p.init_value;
		uint256 x;
		for (uint256 i; i < p.pieces.length; i++) {
			x += p.pieces[i].length;
			uint256 v = _value(p, x);
			if (v > cap)
				cap = v;
		}
		q = _copy(p);
		q.init_value = cap - p.init_value;
		for (uint256 i; i < q.pieces.length; i++)
			q.pieces[i].slope = -q.pieces[i].slope;
		// The identically zero payoff has no normalization count.
		if (_referenceDivisor(q) == 0) {
			cap++;
			q.init_value++;
		}
	}

	function _balance(uint256 localId) internal view returns (uint256) {
		return manager.balanceOf(address(this), HashLib.hash(address(prediction), localId));
	}

	function _positions(uint256 pId, uint256 pCount, uint256 qId, uint256 qCount) internal view {
		assertEq(_balance(pId), pCount + (pId == qId ? qCount : 0));
		assertEq(_balance(qId), qCount + (pId == qId ? pCount : 0));
	}
}

contract PredictionBlueprintTest is PredictionBlueprintIntegrationBase {
	function test_redemptionAtZeroAndRecoveryBreakpoints() public {
		Payoff memory p = Payoff(2, new Range[](2));
		p.pieces[0] = Range(-1, 2);
		p.pieces[1] = Range(2, 3);
		uint256[7] memory readings = [uint256(0), 1, 2, 3, 4, 5, 6];
		uint256[7] memory payouts = [uint256(2), 1, 0, 2, 4, 6, 6];
		Constraint[] memory c = new Constraint[](0);
		for (uint256 i; i < readings.length; i++) {
			uint256 underlying = HashLib.hash(address(this), i);
			bytes32 feed = bytes32(HashLib.hash(address(this), i));
			oracle.cache(bytes32(i), readings[i]);
			manager.mint(address(this), i, payouts[i]);
			_cook(_action(true, false, underlying, feed, c, p, p));
			(uint256 id, uint256 count) = _claim(c, underlying, feed, p);
			assertEq(count, 1);
			assertEq(_balance(id), 1);
			assertEq(manager.balanceOf(address(this), underlying), 0);
			assertEq(manager.balanceOf(address(prediction), underlying), payouts[i]);
			_cook(_action(true, true, underlying, feed, c, p, p));
			assertEq(_balance(id), 0);
			assertEq(manager.balanceOf(address(this), underlying), payouts[i]);
			assertEq(manager.balanceOf(address(prediction), underlying), 0);
		}
	}

	function test_splitConstantOperandUsesUnmodifiedSum() public view {
		Constraint[] memory c = new Constraint[](0);
		bytes32 feed = bytes32(uint256(7));
		Result memory split = _result(_action(false, false, 42, feed, c, _line(2, 2, 1), _constant(1)));
		Constraint[] memory expected = new Constraint[](1);
		expected[0] = Constraint(feed, keccak256(abi.encode(_line(3, 2, 1))));
		assertEq(split.burn.length, 1);
		_op(split.burn, 0, uint256(keccak256(abi.encode(expected, uint256(42)))), 1);
		expected[0].payoff_hash = keccak256(abi.encode(_line(1, 1, 1)));
		_op(split.mint, 0, uint256(keccak256(abi.encode(expected, uint256(42)))), 2);
		expected[0].payoff_hash = keccak256(abi.encode(_constant(1)));
		_op(split.mint, 1, uint256(keccak256(abi.encode(expected, uint256(42)))), 1);
	}

	function testFuzz_splitMergeOperations(
		uint256 underlying,
		bytes32 feed,
		Constraint[] memory c,
		Range[] memory a,
		Range[] memory b,
		uint256 seed
	) public view {
		Payoff memory p = _valid(seed, a);
		Payoff memory q = _valid(seed >> 128, b);
		Result memory split = _result(_action(false, false, underlying, feed, c, p, q));
		_inverse(split, _result(_action(false, true, underlying, feed, c, p, q)));
		assertEq(split.mint.length, 2);
		assertEq(split.give.length, 0);
		(uint256 pId, uint256 pCount) = _claim(c, underlying, feed, p);
		(uint256 qId, uint256 qCount) = _claim(c, underlying, feed, q);
		_op(split.mint, 0, pId, pCount);
		_op(split.mint, 1, qId, qCount);
		(uint256 sumCount, Payoff memory sum) = _referenceNormalize(_referenceSum(p, q));
		if (sum.pieces.length == 0 && c.length == 0) {
			assertEq(split.burn.length, 0);
			assertEq(split.take.length, 1);
			_op(split.take, 0, underlying, sumCount);
		} else {
			assertEq(split.take.length, 0);
			assertEq(split.burn.length, 1);
			uint256 collateralId = sum.pieces.length == 0 ? _id(c, underlying) :
				_id(_insert(c, feed, keccak256(abi.encode(sum))), underlying);
			_op(split.burn, 0, collateralId, sumCount);
		}
	}

	function testFuzz_redemptionOperations(
		uint256 underlying,
		bytes32 key,
		Constraint[] memory c,
		Range[] memory ranges,
		uint256 seed,
		uint256 reading
	) public {
		Payoff memory p = _valid(seed, ranges);
		reading = _reading(p, reading);
		oracle.cache(key, reading);
		bytes32 feed = bytes32(HashLib.hash(address(this), uint256(key)));
		Result memory redeem = _result(_action(true, true, underlying, feed, c, p, p));
		_inverse(redeem, _result(_action(true, false, underlying, feed, c, p, p)));
		assertEq(redeem.burn.length, 1);
		assertEq(redeem.take.length, 0);
		(uint256 id, uint256 count) = _claim(c, underlying, feed, p);
		_op(redeem.burn, 0, id, count);
		uint256 value = _value(p, reading);
		if (c.length == 0) {
			assertEq(redeem.mint.length, 0);
			assertEq(redeem.give.length, 1);
			_op(redeem.give, 0, underlying, value);
		} else {
			assertEq(redeem.give.length, 0);
			assertEq(redeem.mint.length, 1);
			_op(redeem.mint, 0, _id(c, underlying), value);
		}
	}


	function testFuzz_collateralConservationRoundTrip(
		uint256 seed,
		Range[] memory ranges,
		uint256 reading,
		uint8 depthSeed
	) public {
		Payoff memory p = _valid(seed, ranges);
		(Payoff memory q, uint256 cap) = _complement(p);
		reading = _reading(p, reading);
		uint256 underlying = HashLib.hash(address(this), seed);
		manager.mint(address(this), seed, cap);
		oracle.cache(0, reading);
		bytes32 feed = bytes32(HashLib.hash(address(this), 0));
		uint256 depth = depthSeed % 4;
		Constraint[][] memory contexts = new Constraint[][](depth + 1);
		contexts[0] = new Constraint[](0);
		Payoff memory funding = _constant(cap);
		for (uint256 i; i < depth; i++) {
			_cook(_action(true, false, underlying, feed, contexts[i], funding, funding));
			contexts[i + 1] = _insert(contexts[i], feed, keccak256(abi.encode(_constant(1))));
			assertEq(_balance(_id(contexts[i + 1], underlying)), cap);
			if (i != 0)
				assertEq(_balance(_id(contexts[i], underlying)), 0);
		}
		Constraint[] memory c = contexts[depth];
		(uint256 pId, uint256 pCount) = _claim(c, underlying, feed, p);
		(uint256 qId, uint256 qCount) = _claim(c, underlying, feed, q);
		bytes memory split = _action(false, false, underlying, feed, c, p, q);
		bytes memory merge = _action(false, true, underlying, feed, c, p, q);
		_cook(split);
		_positions(pId, pCount, qId, qCount);
		assertEq(manager.balanceOf(address(this), underlying), 0);
		assertEq(manager.balanceOf(address(prediction), underlying), cap);
		if (depth != 0)
			assertEq(_balance(_id(c, underlying)), 0);
		_cook(merge);
		_positions(pId, 0, qId, 0);
		_cook(split);
		_cook(_action(true, true, underlying, feed, c, p, p));
		_positions(pId, 0, qId, qCount);
		uint256 paid = _value(p, reading);
		if (depth == 0) {
			assertEq(manager.balanceOf(address(this), underlying), paid);
			assertEq(manager.balanceOf(address(prediction), underlying), cap - paid);
		} else {
			assertEq(_balance(_id(c, underlying)), paid);
		}
		_cook(_action(true, true, underlying, feed, c, q, q));
		_positions(pId, 0, qId, 0);
		if (depth == 0)
			assertEq(manager.balanceOf(address(this), underlying), cap);
		else
			assertEq(_balance(_id(c, underlying)), cap);

		// Reverse redemption must fund exactly the same claims; then merge them.
		_cook(_action(true, false, underlying, feed, c, q, q));
		_cook(_action(true, false, underlying, feed, c, p, p));
		_positions(pId, pCount, qId, qCount);
		_cook(merge);
		_positions(pId, 0, qId, 0);
		for (uint256 i = depth; i != 0; i--) {
			_cook(_action(true, true, underlying, feed, contexts[i - 1], funding, funding));
			assertEq(_balance(_id(contexts[i], underlying)), 0);
		}
		assertEq(manager.balanceOf(address(this), underlying), cap, "all collateral returned");
		assertEq(manager.balanceOf(address(prediction), underlying), 0, "no escrow residue");
	}

	function testFuzz_nonconstantCollateralRoundTrip(
		uint256 seed,
		Range[] memory a,
		Range[] memory b,
		uint256 reading
	) public {
		Payoff memory p = _valid(seed, a);
		Payoff memory q = _valid(seed >> 128, b);
		Payoff memory sum = _referenceSum(p, q);
		(uint256 sumCount, Payoff memory normalized) = _referenceNormalize(sum);
		reading = _reading(reading % 2 == 0 ? p : q, reading / 2);
		uint256 funding = _value(p, reading) + _value(q, reading);
		uint256 underlying = HashLib.hash(address(this), 0);
		bytes32 feed = bytes32(HashLib.hash(address(this), 0));
		Constraint[] memory c = new Constraint[](0);
		manager.mint(address(this), 0, funding);
		oracle.cache(0, reading);
		(uint256 sumId,) = _claim(c, underlying, feed, sum);
		if (normalized.pieces.length != 0) {
			_cook(_action(true, false, underlying, feed, c, sum, sum));
			assertEq(_balance(sumId), sumCount);
		}
		(uint256 pId, uint256 pCount) = _claim(c, underlying, feed, p);
		(uint256 qId, uint256 qCount) = _claim(c, underlying, feed, q);
		bytes memory split = _action(false, false, underlying, feed, c, p, q);
		_cook(split);
		_positions(pId, pCount, qId, qCount);
		if (sumId != pId && sumId != qId)
			assertEq(_balance(sumId), 0);
		assertEq(manager.balanceOf(address(this), underlying), 0);
		assertEq(manager.balanceOf(address(prediction), underlying), funding);
		_cook(_action(false, true, underlying, feed, c, p, q));
		if (normalized.pieces.length != 0) {
			assertEq(_balance(sumId), sumCount);
			assertEq(_balance(pId), pId == sumId ? sumCount : 0);
			assertEq(_balance(qId), qId == sumId ? sumCount : 0);
		} else {
			_positions(pId, 0, qId, 0);
			assertEq(manager.balanceOf(address(this), underlying), funding);
		}
		_cook(split);
		_cook(_action(true, true, underlying, feed, c, p, p));
		_positions(pId, 0, qId, qCount);
		assertEq(manager.balanceOf(address(this), underlying), _value(p, reading));
		_cook(_action(true, true, underlying, feed, c, q, q));
		_positions(pId, 0, qId, 0);
		assertEq(_balance(sumId), 0);
		assertEq(manager.balanceOf(address(this), underlying), funding);
		assertEq(manager.balanceOf(address(prediction), underlying), 0);
	}

	function testFuzz_operationSequence(
		uint16[] memory steps,
		uint32 cutSeed,
		uint256 readingSeed
	) public {
		uint256 cut = uint256(cutSeed) + 1;
		uint256 reading = _reading(_line(0, 1, cut), readingSeed);
		uint256 pValue = reading < cut ? reading : cut;
		uint256 qValue = cut - pValue;
		Payoff memory p = _line(0, 1, cut);
		Payoff memory q = _line(cut, -1, cut);
		uint256 underlying = HashLib.hash(address(this), 0);
		bytes32 feed = bytes32(HashLib.hash(address(this), 0));
		Constraint[] memory c = new Constraint[](0);
		(uint256 pId,) = _claim(c, underlying, feed, p);
		(uint256 qId,) = _claim(c, underlying, feed, q);
		uint256 initial = 1e18;
		uint256 cash = initial;
		uint256 pHeld;
		uint256 qHeld;
		manager.mint(address(this), 0, initial);
		oracle.cache(0, reading);
		uint256 n = steps.length < 32 ? steps.length : 32;
		for (uint256 i; i < n; i++) {
			uint256 operation = steps[i] % 6;
			uint256 amount = 1 + (steps[i] / 6) % 1000;
			if (operation == 0) {
				if (amount > cash / cut)
					amount = cash / cut;
				if (amount == 0)
					continue;
				_cook(_action(false, false, underlying, feed, c, _scaled(p, amount), _scaled(q, amount)));
				cash -= amount * cut;
				pHeld += amount;
				qHeld += amount;
			} else if (operation == 1) {
				if (amount > pHeld)
					amount = pHeld;
				if (amount > qHeld)
					amount = qHeld;
				if (amount == 0)
					continue;
				_cook(_action(false, true, underlying, feed, c, _scaled(p, amount), _scaled(q, amount)));
				cash += amount * cut;
				pHeld -= amount;
				qHeld -= amount;
			} else {
				bool first = operation == 2 || operation == 4;
				bool redeem = operation < 4;
				uint256 price = first ? pValue : qValue;
				uint256 held = first ? pHeld : qHeld;
				if (redeem && amount > held)
					amount = held;
				if (!redeem && price != 0 && amount > cash / price)
					amount = cash / price;
				if (amount == 0)
					continue;
				Payoff memory claim = _scaled(first ? p : q, amount);
				_cook(_action(true, redeem, underlying, feed, c, claim, claim));
				if (redeem) {
					cash += amount * price;
					if (first)
						pHeld -= amount;
					else
						qHeld -= amount;
				} else {
					cash -= amount * price;
					if (first)
						pHeld += amount;
					else
						qHeld += amount;
				}
			}
			_positions(pId, pHeld, qId, qHeld);
			assertEq(manager.balanceOf(address(this), underlying), cash, "modeled cash");
			uint256 escrow = manager.balanceOf(address(prediction), underlying);
			assertEq(escrow + cash, initial, "total collateral");
			assertEq(escrow, pHeld * pValue + qHeld * qValue, "exact outstanding liabilities");
		}
		if (pHeld != 0)
			_cook(_action(true, true, underlying, feed, c, _scaled(p, pHeld), p));
		if (qHeld != 0)
			_cook(_action(true, true, underlying, feed, c, _scaled(q, qHeld), q));
		_positions(pId, 0, qId, 0);
		assertEq(manager.balanceOf(address(this), underlying), initial);
		assertEq(manager.balanceOf(address(prediction), underlying), 0);
	}

	function testFuzz_unfundedAndMismatchedClaimsRevert(
		uint64 amountSeed,
		uint64 cutSeed,
		uint256 reading
	) public {
		uint256 amount = uint256(amountSeed) + 1;
		uint256 cut = uint256(cutSeed) + 2;
		// Keep enough escrow for doubled and repeated payouts; only ownership is invalid.
		reading %= cut / 2 + 1;
		uint256 cap = amount * cut;
		uint256 underlying = HashLib.hash(address(this), 0);
		bytes32 feed = bytes32(HashLib.hash(address(this), 0));
		Constraint[] memory c = new Constraint[](0);
		Payoff memory p = _line(0, int256(amount), cut);
		Payoff memory q = _line(cap, -int256(amount), cut);
		bytes memory split = _action(false, false, underlying, feed, c, p, q);
		vm.expectRevert(AccountingLib.BalanceUnderflow.selector);
		_cook(split);
		assertEq(manager.balanceOf(address(prediction), underlying), 0);
		manager.mint(address(this), 0, cap);
		_cook(split);
		(uint256 pId, uint256 pCount) = _claim(c, underlying, feed, p);
		(uint256 qId, uint256 qCount) = _claim(c, underlying, feed, q);
		bytes memory redeem = _action(true, true, underlying, feed, c, p, p);
		vm.expectRevert(bytes("Reading not cached yet"));
		_cook(redeem);
		oracle.cache(0, reading);
		// A different feed or underlying cannot spend the original claim or escrow.
		oracle.cache(bytes32(uint256(1)), reading);
		bytes32 otherFeed = bytes32(HashLib.hash(address(this), 1));
		uint256 otherUnderlying = HashLib.hash(address(this), 1);
		manager.mint(address(prediction), 1, cap);
		vm.expectRevert(AccountingLib.BalanceUnderflow.selector);
		_cook(_action(true, true, underlying, otherFeed, c, p, p));
		vm.expectRevert(AccountingLib.BalanceUnderflow.selector);
		_cook(_action(true, true, otherUnderlying, feed, c, p, p));
		vm.expectRevert(AccountingLib.BalanceUnderflow.selector);
		_cook(_action(true, true, underlying, feed, c, _scaled(p, 2), p));
		assertEq(manager.balanceOf(address(prediction), otherUnderlying), cap);
		assertEq(manager.balanceOf(address(this), otherUnderlying), 0);
		_positions(pId, pCount, qId, qCount);
		assertEq(manager.balanceOf(address(prediction), underlying), cap);
		assertEq(manager.balanceOf(address(this), underlying), 0);
		_cook(redeem);
		uint256 paid = amount * (reading < cut ? reading : cut);
		assertEq(manager.balanceOf(address(this), underlying), paid);
		vm.expectRevert(AccountingLib.BalanceUnderflow.selector);
		_cook(redeem);
		_positions(pId, 0, qId, qCount);
		assertEq(manager.balanceOf(address(this), underlying), paid);
		assertEq(manager.balanceOf(address(prediction), underlying), cap - paid);
		_cook(_action(true, true, underlying, feed, c, q, q));
		assertEq(manager.balanceOf(address(this), underlying), cap);
		assertEq(manager.balanceOf(address(prediction), underlying), 0);
	}
}
