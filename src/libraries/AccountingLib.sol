// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library AccountingLib {
	uint256 constant _2_POW_254 = 1 << 254;
	uint256 constant _2_POW_255 = 1 << 255;
	uint256 constant NEG_1 = (1 << 256) - 1;
	uint256 constant INT_MAX = (1 << 255) - 1;

	error BalanceUnderflow();

	function balanceOf(uint256 ptr) internal view returns (uint256 res) {
		assembly ("memory-safe") {
			res := sload(ptr) // | 1 bit more | 255 bit uint255 val |
			if slt(res, 0) { // whether we should read the next slot
				if sub(sload(add(ptr, 1)), 1) { // if carry is 1, res is already good
					res := NEG_1 // return type(uint256).max
				}
			}
		}
	}

	// returns the PREVIOUS deltaCal, from before the execution
	function addFlashValue(uint256 slot, uint256 amount) internal returns (int256 deltaVal) {
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
	function subtractFlashValue(uint256 slot, uint256 amount) internal returns (int256 deltaVal) {
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

	function readAndNullifyFlashValue(uint256 tslot, uint256 sslot) internal {
		int256 delta;
		assembly ("memory-safe") {
			delta := tload(tslot)
		}

		if (delta == 0)
			return;

		assembly ("memory-safe") {
			let tcarry := and(delta, 1)
			delta := sar(1, delta)
			let lsb := sload(sslot)
			let lsb_val := and(lsb, INT_MAX)
			let sum := add(delta, lsb_val)
			let carry := 0

			switch shr(254, sum)
			case 2 { // int255 + uint255 overflow
				carry := 1
				sum := sub(sum, _2_POW_255)
			} case 3 { // int255 + uint255 underflow
				carry := NEG_1
				sum := add(sum, _2_POW_255)
			} /* default // case 0-1 // {} */

			if tcarry {
				carry := add(carry, tload(add(tslot, 1)))
			}

			switch carry // by how much we have to modify the storage carry...
			case 0 {
				sstore(sslot, or(and(lsb, _2_POW_255), sum))
			} default /*nonzero*/ {
				let msb_sslot := add(sslot, 1) // it's now msb
				carry := add(carry, sload(msb_sslot)) // final carry
				if slt(carry, 0) {
					mstore(0, 0x0bce5a72) // bytes4(keccak256("BalanceUnderflow()"))
					revert(0x1c, 0x04)
				}
				sstore(msb_sslot, carry)
				sstore(sslot, or(shl(255, iszero(iszero(carry))), sum))
			}

			tstore(tslot, 0) // this also clears the extension since it will be ignored
		}
	}

	function _mintInternal(uint256 ptr, uint256 amount) internal {
		assembly ("memory-safe") {
			let lsb := sload(ptr) // | 1 bit more | 255 bit uint255 val |
			let more := slt(lsb, 0) // whether we should read the next slot
			let val := and(INT_MAX, lsb) // uint255 val
			let res := add(val, amount)
			let msb := 0 // if we don't have to read msb, it's zero; else we'll read
			switch gt(val, res)
			case 0 { // not overflowing twice
				switch slt(res, 0) // get first bit of res
				case 0 { // no overflow
					sstore(ptr, add(lsb, amount)) // addition doesn't overflow and msb bit is maintained
				} case 1 { // uint256 + uint255 overflow uint255 once
					if more {
						msb := sload(add(ptr, 1))
					}
					sstore(ptr, res) // first bit is already set to 1
					sstore(add(ptr, 1), add(msb, 1))
				}
			} case 1 { // uint256 + uint255 overflow uint255 twice
				if more {
					msb := sload(add(ptr, 1))
				}
				sstore(ptr, or(res, not(INT_MAX))) // set the first bit
				sstore(add(ptr, 1), add(msb, 2))
			}
		}
	}

	function _burnInternal(uint256 ptr, uint256 amount) internal {
		assembly ("memory-safe") {
			let lsb := sload(ptr) // | 1 bit more | 255 bit uint255 val |
			let more := slt(lsb, 0) // whether we should read the next slot
			let val := and(INT_MAX, lsb) // uint255 val
			switch gt(amount, val)
			case 0 { // not underflowing
				sstore(ptr, sub(lsb, amount)) // can't underflow, maintaining first bit of lsb
			} case 1 { // underflowing
				let res := sub(val, amount)
				let first_bit := slt(res, 0)

				let msb := 0
				if more {
					msb := sload(add(ptr, 1))
				}
				let msb_res := sub(msb, sub(2, first_bit)) // subtract (res >> 255) ? 1 : 2

				if gt(msb_res, msb) { // underflow
					mstore(0, 0xf4d678b8) // bytes4(keccak256("InsufficientBalance()"))
					revert(28, 4)
				}
				let change := shl(255, eq(iszero(msb_res), first_bit)) // flip the first bit
				sstore(ptr, xor(res, change))
				sstore(add(ptr, 1), msb_res)
			}
		}
	}
}
