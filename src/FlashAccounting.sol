// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// keccak256(MainClue | 0)
type FlashSession is uint256;
// keccak256(user | FlashSession)
type FlashUserSession is uint256;
// tload(0) before the execution of this function
type MainClue is uint256;
// tload(FlashSession)
type SessionClue is uint256;
// tload(FlashUserSession)
type UserClue is uint256;

uint256 constant _2_POW_254 = 1 << 254;
uint256 constant _96_BIT_FLAG = (1 << 96) - 1;

abstract contract FlashAccounting {
	function _mint(address to, uint256 id, uint256 amount) internal virtual;
	function _burn(address from, uint256 id, uint256 amount) internal virtual;

	error BalanceDeltaOverflow();
	error NoFlashAccountingActive();

	function exttload(uint256 slot) external view returns (uint256 value) {
		assembly ("memory-safe") {
			value := tload(slot)
		}
	}

	function getCurrentSessionAndRealizer() internal view returns (
		FlashSession session,
		address realizer
	) {
		uint256 mainIndex;
		assembly ("memory-safe") {
			let mainClue := tload(0)
			mainIndex := and(mainClue, _96_BIT_FLAG)
			realizer := shr(96, mainClue)
		}

		if (mainIndex == 0)
			revert NoFlashAccountingActive();

		assembly ("memory-safe") {
			mstore(0, sub(mainIndex, 1))
			mstore(0x20, 0)

			session := keccak256(20, 44)
		}
	}

	// authorizedCaller is of type bytes32 so that top bits would be certain to
	// be clear across Solidity code
	function openFlashAccounting(address realizer) internal returns (
		FlashSession session,
		MainClue mainClue
	) {
		assembly ("memory-safe") {
			mainClue := tload(0)
			tstore(0, or(shl(96, realizer), add(and(mainClue, _96_BIT_FLAG), 1)))

			mstore(0, mainClue)
			mstore(0x20, 0)

			session := keccak256(20, 44)
		}
	}

	function closeFlashAccounting(
		MainClue mainClue,
		FlashSession session
	) internal {
		settleSession(session);

		assembly ("memory-safe") {
			tstore(0, mainClue)
		}
	}

	function getUserSession(
		FlashSession session,
		address user
	) internal pure returns (FlashUserSession userSession) {
		assembly ("memory-safe") {
			mstore(0, user)
			mstore(0x20, session)

			userSession := keccak256(12, 52)
		}
	}

	function getUserClue(FlashUserSession userSession) internal view returns (UserClue userClue) {
		assembly {
			userClue := tload(userSession)
		}
	}

	function initializeUserSession(
		FlashSession session,
		address user
	) internal returns (
		FlashUserSession userSession,
		UserClue userClue
	) {
		userSession = getUserSession(session, user);

		assembly {
			userClue := tload(userSession)

			if iszero(userClue) {
				let sessionClue := add(tload(session), 1)
				tstore(session, sessionClue)
				// can have dirty top bits but that has no impact
				tstore(add(session, sessionClue), user)
			}
		}

		return (userSession, userClue);
	}

	// NOTE: mustn't be used when user session is not initialized in the session
	// NOTE: is dependent on the clue, wrong clue WILL cause the entire system
	//       to break!
	// NOTE: it's easy to break the system if someone has accidentally two user
	//       sessions initialized at once, for example if the sender is the
	//       blueprint
	function addUserCreditWithClue(
		FlashUserSession userSession,
		UserClue userClue,
		uint256 id,
		uint256 amount
	) internal returns (UserClue) {
		assembly ("memory-safe") {
			mstore(0, id)
			mstore(0x20, userSession)

			let deltaSlot := keccak256(0, 0x40)

			// Structure: | int255 value | 1 bit extension |
			let deltaVal := tload(deltaSlot)

			let delta := sar(1, deltaVal)
			let newDelta := add(delta, amount)

			// we'll have a carry if the addition overflows integers or if the
			// first two bits are 01, which are out of bounds of int255
			switch or(slt(newDelta, delta), eq(shr(254, newDelta), 1))
			case 1 {
				let preDeltaSlot := add(deltaSlot, 1)
				// if first bits are 01 or 10, the carry is 1, else 2
				let carry := sub(2, shr(255, add(newDelta, _2_POW_254)))

				// ignore preDeltaSlot if there is no extension
				let preDelta := 0
				if and(deltaVal, 1) {
					preDelta := tload(preDeltaSlot)
				}
				preDelta := add(preDelta, carry)

				tstore(preDeltaSlot, preDelta)
				tstore(
					deltaSlot,
					or(
						shl(1, newDelta),
						iszero(iszero(preDelta))
					)
				)
			}
			default /*case 0*/ {
				tstore(
						deltaSlot,
						or(
							shl(1, newDelta),
							and(deltaVal, 1)
						)
					)
			}

			// it means we may need to push the token
			if iszero(deltaVal) {
				userClue := add(userClue, 1)
				// we save user clue lazily
				// tstore(userSession, userClue)
				tstore(add(userSession, userClue), id)
			}
		}

		return userClue;
	}

	// NOTE: mustn't be used when user session is not initialized in the session
	// NOTE: is dependent on the clue, wrong clue WILL cause the entire system
	//       breaking!
	// NOTE: it's easy to break the system if someone has accidentally two user
	//       sessions initialized at once, for example if the sender is the
	//       blueprint
	function addUserDebitWithClue(
		FlashUserSession userSession,
		UserClue userClue,
		uint256 id,
		uint256 amount
	) internal returns (UserClue) {
		assembly ("memory-safe") {
			mstore(0, id)
			mstore(0x20, userSession)

			let deltaSlot := keccak256(0, 0x40)

			// Structure: | int255 value | 1 bit extension |
			let deltaVal := tload(deltaSlot)

			let delta := sar(1, deltaVal)
			let newDelta := sub(delta, amount)

			// we'll have a carry if the subtraction underflows integers or if
			// the first two bits are 10, which are out of bounds of int255
			switch or(slt(delta, newDelta), eq(shr(254, newDelta), 2))
			case 1 {
				let preDeltaSlot := add(deltaSlot, 1)
				// if first bits are 01 or 10, the carry is 1, else 2
				let carry := sub(2, shr(255, add(newDelta, _2_POW_254)))

				// ignore preDeltaSlot if there is no extension
				let preDelta := 0
				if and(deltaVal, 1) {
					preDelta := tload(preDeltaSlot)
				}
				preDelta := sub(preDelta, carry)

				tstore(preDeltaSlot, preDelta)
				tstore(
					deltaSlot,
					or(
						shl(1, newDelta),
						iszero(iszero(preDelta))
					)
				)
			}
			default /*case 0*/ {
				tstore(
						deltaSlot,
						or(
							shl(1, newDelta),
							and(deltaVal, 1)
						)
					)
			}

			// it means we may need to push the token
			if iszero(deltaVal) {
				userClue := add(userClue, 1)
				// we save user clue lazily
				// tstore(userSession, userClue)
				tstore(add(userSession, userClue), id)
			}
		}

		return userClue;
	}

	function saveUserClue(FlashUserSession userSession, UserClue userClue) internal {
		assembly ("memory-safe") {
			tstore(userSession, userClue)
		}
	}

	function settleUserBalances(FlashUserSession userSession, address user) private {
		UserClue userClue = getUserClue(userSession);

		for (uint256 i = 0; i < UserClue.unwrap(userClue);) {
			uint256 id;
			int256 delta;
			uint256 deltaSlot;

			assembly ("memory-safe") {
				i := add(1, i)
				id := tload(add(userSession, i))

				mstore(0, id)
				mstore(0x20, userSession)
				deltaSlot := keccak256(0, 0x40)

				delta := tload(deltaSlot)
			}

			if (delta == 0)
				continue;

			bool more;
			assembly ("memory-safe") {
				more := and(delta, 1)
				delta := sar(1, delta)

				// optimistically clear the delta; this also clears the
				// extension since it will be ignored if the delta is read
				tstore(deltaSlot, 0)
			}

			unchecked {
				if (more) {
					int256 extension;
					assembly ("memory-safe") {
						extension := tload(add(deltaSlot, 1))
					}

					if (extension == -2) {
						if (delta < 0)
							revert BalanceDeltaOverflow();
						// burn 2 ** 256 - uint256(delta) tokens
						_burn(user, id, uint256(-delta));
					} else if (extension == -1) {
						_burn(user, id, uint256(-delta) + (1 << 255));
					} /* else if (extension == 0) {
						// in that case !more, so we won't enter this branch
					} */ else if (extension == 1) {
						_mint(user, id, uint256(delta) + (1 << 255));
					} else if (extension == 2) {
						if (delta >= 0)
							revert BalanceDeltaOverflow();
						// mint 2 ** 256 + delta tokens (delta is negative)
						_mint(user, id, uint256(delta));
					} else
						revert BalanceDeltaOverflow();
				} else {
					if (delta < 0)
						_burn(user, id, uint256(-delta));
					else
						_mint(user, id, uint256(delta));
				}
			}
		}

		assembly ("memory-safe") {
			// reset the user unsettled token id array
			tstore(userSession, 0)
		}
	}

	function settleSession(
		FlashSession session
	) private {
		SessionClue sessionClue;
		assembly ("memory-safe") {
			sessionClue := tload(session)
		}

		for (uint256 i = 0; i < SessionClue.unwrap(sessionClue);) {
			address user;
			assembly ("memory-safe") {
				i := add(1, i)
				user := tload(add(session, i))
			}

			settleUserBalances(getUserSession(session, user), user);

			assembly ("memory-safe") {
				// reset the session
				tstore(session, 0)
			}
		}
	}
}
