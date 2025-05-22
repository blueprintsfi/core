// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FlashAccountingLib} from "./libraries/FlashAccountingLib.sol";
import {HashLib} from "./libraries/HashLib.sol";
import {IFlashAccounting} from "./interfaces/IFlashAccounting.sol";

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

abstract contract FlashAccounting is IFlashAccounting {
	function _mintInternal(address to, uint256 complexId, uint256 amount) internal virtual;
	function _burnInternal(address from, uint256 complexId, uint256 amount) internal virtual;

	error BalanceDeltaOverflow();
	error NoFlashAccountingActive();
	error RealizeAccessDenied();

	function exttload(uint256 slot) public view virtual returns (uint256 value) {
		assembly ("memory-safe") {
			value := tload(slot)
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
			mstore(0x20, 0)

			session := keccak256(20, 44)
		}

		if (realizer != address(0) && realizer != msg.sender)
			revert RealizeAccessDenied();
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

	function closeFlashAccounting(MainClue mainClue, FlashSession session) internal {
		settleSession(session);

		assembly ("memory-safe") {
			tstore(0, mainClue)
		}
	}

	function getUserSession(FlashSession session, address user) internal pure returns (FlashUserSession) {
		return FlashUserSession.wrap(HashLib.hash(user, FlashSession.unwrap(session)));
	}

	function getUserClue(FlashUserSession userSession) internal view returns (UserClue userClue) {
		assembly {
			userClue := tload(userSession)
		}
	}

	function initializeUserSession(FlashSession session, address user) internal returns (
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
		uint256 subaccount,
		uint256 id,
		uint256 amount
	) internal returns (UserClue) {
		id = HashLib.hash(id, subaccount);
		uint256 deltaSlot = HashLib.hash(id, FlashUserSession.unwrap(userSession));
		int256 deltaVal = FlashAccountingLib.addFlashValue(deltaSlot, amount);

		assembly ("memory-safe") {
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
		uint256 subaccount,
		uint256 id,
		uint256 amount
	) internal returns (UserClue) {
		id = HashLib.hash(id, subaccount);
		uint256 deltaSlot = HashLib.hash(id, FlashUserSession.unwrap(userSession));
		int256 deltaVal = FlashAccountingLib.subtractFlashValue(deltaSlot, amount);

		assembly ("memory-safe") {
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
			assembly ("memory-safe") {
				i := add(1, i)
				id := tload(add(userSession, i))
			}

			uint256 deltaSlot = HashLib.hash(id, FlashUserSession.unwrap(userSession));
			(uint256 positive, uint256 negative) =
				FlashAccountingLib.readAndNullifyFlashValue(deltaSlot);

			if (positive != 0)
				_mintInternal(user, id, positive);
			else if (negative != 0)
				_burnInternal(user, id, negative);
		}

		assembly ("memory-safe") {
			// reset the user unsettled token id array
			tstore(userSession, 0)
		}
	}

	function settleSession(FlashSession session) private {
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
