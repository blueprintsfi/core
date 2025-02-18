// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library FlashAccountingLib {
	uint256 constant _2_POW_254 = 1 << 254;
	uint256 constant _2_POW_255 = 1 << 255;
	uint256 constant NEG_1 = (1 << 256) - 1;

	error BalanceDeltaOverflow();

	// returns the PREVIOUS deltaCal, from before the execution
	function addFlashValue(
		uint256 slot,
		uint256 amount
	) internal returns (int256 deltaVal) {
		assembly ("memory-safe") {
			// Structure: | int255 value | 1 bit extension |
			deltaVal := tload(slot)

			let delta := sar(1, deltaVal) // delta as int256, [-2 ** 254, 2 ** 254 - 1]
			let newDelta := add(delta, amount)

			// slt(newDelta, delta) will be 1 iff we had an overflow adding uint256 to int256
			// else, int256(newDelta) is in range [-2 ** 254, 2 ** 255 - 1] and
			// we'll have a carry now iff it's in range [2 ** 254, 2 ** 255 - 1]
			// which is equivalent to (newDelta >> 254) == 1
			switch or(slt(newDelta, delta), eq(shr(254, newDelta), 1))
			case 0 {
				tstore(
					slot,
					or(
						shl(1, newDelta),
						and(deltaVal, 1)
					)
				)
			}
			default /* case 1 */ {
				let preSlot := add(slot, 1)
				// ranges of newDelta:
				// [-2 ** 255, -2 ** 254 - 1]: the first bits are 10, we had an
				// overflow (the actual value is 2 ** 256 larger), so we have to
				// subtract 2 ** 255 to move into the int255 range
				// [-2 ** 254, -1]: the first bits are 11, we had an overflow
				// if we're in this case, so the value is 2 ** 256 larger, we
				// have to subtract 2 * 2 ** 255 to move into the int255 range
				// [0, 2 ** 254 - 1]: the first bits are 00, we had an overflow
				// if we're in this case, so the value is 2 ** 256 larger, we
				// have to subtract 2 * 2 ** 255 to move into the int255 range
				// [2 ** 254, 2 ** 255 - 1]: the first bits are 01, we didn't
				// have an overflow, but went outside of the range of int255,
				// so we have to subtract 2 ** 255 to move into the range
				// So: if first bits are 01 or 10, the carry is 1, else 2.
				let carry := sub(2, slt(add(newDelta, _2_POW_254), 0))

				// ignore preSlot if there is no extension
				let preDelta := 0
				if and(deltaVal, 1) {
					preDelta := tload(preSlot)
				}
				preDelta := add(preDelta, carry)

				tstore(preSlot, preDelta)
				tstore(
					slot,
					or(
						shl(1, newDelta),
						iszero(iszero(preDelta))
					)
				)
			}
		}
	}

	// returns the PREVIOUS deltaVal, from before the execution
	function subtractFlashValue(
		uint256 slot,
		uint256 amount
	) internal returns (int256 deltaVal) {
		assembly ("memory-safe") {
			// Structure: | int255 value | 1 bit extension |
			deltaVal := tload(slot)

			let delta := sar(1, deltaVal) // delta as int256, [-2 ** 254, 2 ** 254 - 1]
			let newDelta := sub(delta, amount)

			// slt(delta, newDelta) will be 1 iff we had an underflow subtracting uint256 from int256
			// else, int256(newDelta) is in range [-2 ** 255, 2 ** 254 - 1] and
			// we'll have a carry now iff it's in range [-2 ** 255, -2 ** 254 - 1]
			// which is equivalent to (newDelta >> 254) == 2
			switch or(slt(delta, newDelta), eq(shr(254, newDelta), 2))
			case 0 {
				tstore(
					slot,
					or(
						shl(1, newDelta),
						and(deltaVal, 1)
					)
				)
			}
			default /* case 1 */ {
				let preSlot := add(slot, 1)
				// ranges of newDelta:
				// [-2 ** 255, -2 ** 254 - 1]: the first bits are 10, we didn't
				// have an underflow, but went outside of the range of int255,
				// so we have to add 2 ** 255 to move into the range
				// [-2 ** 254, -1]: the first bits are 11, we had an underflow
				// if we're in this case, so the value is 2 ** 256 smaller,
				// we have to add 2 * 2 ** 255 to move into the int255 range
				// [0, 2 ** 254 - 1]: the first bits are 00, we had an underflow
				// if we're in this case, so the value is 2 ** 256 smaller, we
				// have to add 2 * 2 ** 255 to move into the int255 range
				// [2 ** 254, 2 ** 255 - 1]: the first bits are 01, we had an
				// underflow if we're in this case, so we have to add 2 ** 255
				// to move into the range of int255
				// So: if first bits are 01 or 10, the carry is 1, else 2.
				let carry := sub(2, slt(add(newDelta, _2_POW_254), 0))

				// ignore preSlot if there is no extension
				let preDelta := 0
				if and(deltaVal, 1) {
					preDelta := tload(preSlot)
				}
				preDelta := sub(preDelta, carry)

				tstore(preSlot, preDelta)
				tstore(
					slot,
					or(
						shl(1, newDelta),
						iszero(iszero(preDelta))
					)
				)
			}
		}
	}

	function readAndNullifyFlashValue(
		uint256 slot
	) internal returns (uint256 positive, uint256 negative) {
		int256 delta;
		assembly ("memory-safe") {
			delta := tload(slot)
		}

		if (delta == 0)
			return (positive, negative);

		assembly ("memory-safe") {
			function revertOverflow() {
				// bytes4(keccak256("BalanceDeltaOverflow()"))
				mstore(0, 0x778214eb)
				revert(0x1c, 0x04)
			}

			// optimistically clear the delta; this also clears the extension
			// since it will be ignored with the last bit of delta zeroed
			tstore(slot, 0)

			switch and(delta, 1)
			case 0 {
				delta := sar(1, delta)
				switch slt(delta, 0)
				case 0 { // the value is nonnegative
					positive := delta
				}
				default /* case 1 */ {
					negative := sub(0, delta)
				}
			}
			default /* case 1 */ {
				delta := sar(1, delta)
				let extension := tload(add(slot, 1))

				// revert if extension < -2 or extension > 2
				if gt(add(extension, 2), 4) {
					revertOverflow()
				}

				switch and(extension, 1)
				case 0 {
					switch extension
					// case 0 is impossible since wouldn't reach this branch
					case 2 {
						if sgt(delta, NEG_1) {
							revertOverflow()
						}
						positive := delta
					}
					default /* case -2 */ {
						if slt(delta, 1) {
							revertOverflow()
						}
						negative := sub(0, delta)
					}
				}
				default /* case 1 */ {
					// add or subtract what we will add or subtract
					delta := xor(delta, _2_POW_255)
					switch extension
					case 1 {
						positive := delta
					}
					default /* case -1 */ {
						negative := sub(0, delta)
					}
				}
			}
		}
	}
}