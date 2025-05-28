// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FlashAccountingLib} from "./libraries/FlashAccountingLib.sol";
import {HashLib} from "./libraries/HashLib.sol";
import {IFlashAccounting} from "./interfaces/IFlashAccounting.sol";

// tload(0) before the execution of this function
type MainClue is uint256;
// keccak256(MainClue | 0)
type FlashSession is uint256;
// tload(FlashSession)
type SessionClue is uint256;

struct BalanceInfo {
	uint256 lowBits;
	uint256 highBits;
}

uint256 constant _2_POW_254 = 1 << 254;
uint256 constant _96_BIT_FLAG = (1 << 96) - 1;

function hash(uint256 ptr, FlashSession session) pure returns (uint256) {
	return HashLib.hash(ptr, FlashSession.unwrap(session));
}

abstract contract FlashAccounting is IFlashAccounting {
	mapping(address => mapping(uint256 => BalanceInfo)) private __balanceOf;

	error BalanceDeltaOverflow();
	error NoFlashAccountingActive();
	error RealizeAccessDenied();

	function exttload(uint256 slot) public view virtual returns (uint256 value) {
		assembly ("memory-safe") {
			value := tload(slot)
		}
	}

	function getPtr(address user, uint256 subaccount, uint256 tokenId) internal view returns (uint256 ptr) {
		uint256 complexId = HashLib.hash(tokenId, subaccount);
		BalanceInfo storage info = __balanceOf[user][complexId];
		assembly ("memory-safe") {
			ptr := info.slot
		}
	}

	function _balanceOf(address user, uint256 subaccount, uint256 tokenId) internal view returns (uint256 res) {
		uint256 ptr = getPtr(user, subaccount, tokenId);
		assembly ("memory-safe") {
			res := sload(ptr) // | 1 bit more | 255 bit uint255 val |
			if slt(res, 0) { // whether we should read the next slot
				if sub(sload(add(ptr, 1)), 1) { // if carry is 1, res is already good
					res := sub(0, 1) // return type(uint256).max
				}
			}
		}
	}

	function _mint(address to, uint256 subaccount, uint256 id, uint256 amount) internal {
		_mintInternal(getPtr(to, subaccount, id), amount);
	}

	function _burn(address from, uint256 subaccount, uint256 id, uint256 amount) internal {
		_burnInternal(getPtr(from, subaccount, id), amount);
	}

	function _mintInternal(uint256 ptr, uint256 amount) internal {
		uint256 int_max = uint(type(int256).max);
		assembly ("memory-safe") {
			let lsb := sload(ptr) // | 1 bit more | 255 bit uint255 val |
			let more := slt(lsb, 0) // whether we should read the next slot
			let val := and(int_max, lsb) // uint255 val
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
				sstore(ptr, or(res, not(int_max))) // set the first bit
				sstore(add(ptr, 1), add(msb, 2))
			}
		}
	}

	function _burnInternal(uint256 ptr, uint256 amount) internal {
		uint256 int_max = uint(type(int256).max);
		assembly ("memory-safe") {
			let lsb := sload(ptr) // | 1 bit more | 255 bit uint255 val |
			let more := slt(lsb, 0) // whether we should read the next slot
			let val := and(int_max, lsb) // uint255 val
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

	function getCurrentSession(bool mustBeActive) internal view returns (FlashSession session) {
		address realizer;
		uint256 mainIndex;
		assembly ("memory-safe") {
			let mainClue := tload(0)
			mainIndex := and(mainClue, _96_BIT_FLAG)
			realizer := shr(96, mainClue)
		}

		if (mainIndex == 0) {
			if (mustBeActive)
				revert NoFlashAccountingActive();
			else
				return session;
		}

		assembly ("memory-safe") {
			mstore(0, sub(mainIndex, 1))
			session := keccak256(20, 12)
		}

		if (realizer != address(0) && realizer != msg.sender)
			revert RealizeAccessDenied();
	}

	function openFlashAccounting(address realizer) internal returns (
		FlashSession session,
		MainClue mainClue
	) {
		assembly ("memory-safe") {
			mainClue := tload(0)
			tstore(0, or(shl(96, realizer), add(and(mainClue, _96_BIT_FLAG), 1)))

			mstore(0, mainClue)
			session := keccak256(20, 12)
		}
	}

	function closeFlashAccounting(MainClue mainClue, FlashSession session) internal {
		SessionClue clue = getSessionClue(session);
		for (uint256 i = 0; i < SessionClue.unwrap(clue);) {
			uint256 ptr;
			assembly ("memory-safe") {
				i := add(1, i)
				ptr := tload(add(session, i))
			}

			(uint256 positive, uint256 negative) =
				FlashAccountingLib.readAndNullifyFlashValue(hash(ptr, session));

			if (positive != 0)
				_mintInternal(ptr, positive);
			else if (negative != 0)
				_burnInternal(ptr, negative);

			assembly ("memory-safe") {
				// reset the session
				tstore(session, 0)
			}
		}

		assembly ("memory-safe") {
			tstore(0, mainClue)
		}
	}

	// NOTE: mustn't be used when user session is not initialized in the session
	// NOTE: is dependent on the clue, wrong clue WILL cause the entire system
	//       to break!
	// NOTE: it's easy to break the system if someone has accidentally two user
	//       sessions initialized at once, for example if the sender is the
	//       blueprint
	function addUserCreditWithClue(
		FlashSession session,
		SessionClue sessionClue,
		uint256 ptr,
		uint256 amount
	) internal returns (SessionClue) {
		int256 deltaVal = FlashAccountingLib.addFlashValue(hash(ptr, session), amount);

		assembly ("memory-safe") {
			// it means we may need to push the token
			if iszero(deltaVal) {
				sessionClue := add(sessionClue, 1)
				// we save user clue lazily
				// tstore(session, sessionClue)
				tstore(add(session, sessionClue), ptr)
			}
		}

		return sessionClue;
	}

	// NOTE: mustn't be used when user session is not initialized in the session
	// NOTE: is dependent on the clue, wrong clue WILL cause the entire system
	//       breaking!
	// NOTE: it's easy to break the system if someone has accidentally two user
	//       sessions initialized at once, for example if the sender is the
	//       blueprint
	function addUserDebitWithClue(
		FlashSession session,
		SessionClue sessionClue,
		uint256 ptr,
		uint256 amount
	) internal returns (SessionClue) {
		int256 deltaVal = FlashAccountingLib.subtractFlashValue(hash(ptr, session), amount);

		assembly ("memory-safe") {
			// it means we may need to push the token
			if iszero(deltaVal) {
				sessionClue := add(sessionClue, 1)
				// we save user clue lazily
				// tstore(session, sessionClue)
				tstore(add(session, sessionClue), ptr)
			}
		}

		return sessionClue;
	}

	function getSessionClue(FlashSession session) internal view returns (SessionClue sessionClue) {
		assembly {
			sessionClue := tload(session)
		}
	}

	function saveSessionClue(FlashSession session, SessionClue sessionClue) internal {
		assembly ("memory-safe") {
			tstore(session, sessionClue)
		}
	}
}
