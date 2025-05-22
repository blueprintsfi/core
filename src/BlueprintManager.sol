// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import { HashLib } from "./libraries/HashLib.sol";
import {
	CalldataTokenOpArray,
	getSubaccount,
	hashActionResults,
	getTokenOpArray,
	at
} from "./libraries/CalldataTokenOp.sol";
import { IBlueprint } from "./interfaces/IBlueprint.sol";
import { IBlueprintManager, TokenOp, BlueprintCall } from "./interfaces/IBlueprintManager.sol";
import {
	FlashAccounting,
	FlashSession,
	MainClue,
	FlashUserSession,
	UserClue
} from "./FlashAccounting.sol";

using { at } for CalldataTokenOpArray;

contract BlueprintManager is FlashAccounting, IBlueprintManager {
	error InvalidChecksum();
	error AccessDenied();

	mapping(address => mapping(address => bool)) public isOperator;
	mapping(address => mapping(uint256 => uint256)) private _balanceOf;
	mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

	function balanceOf(address user, uint256 subaccount, uint256 tokenId) public view returns (uint256) {
		return _balanceOf[user][HashLib.hash(tokenId, subaccount)];
	}

	function balanceOf(address user, uint256 tokenId) public view returns (uint256 balance) {
		return balanceOf(user, 0, tokenId);
	}

	function _mintInternal(address to, uint256 complexId, uint256 amount) internal override {
		_balanceOf[to][complexId] += amount;
	}

	function _burnInternal(address from, uint256 complexId, uint256 amount) internal override {
		_balanceOf[from][complexId] -= amount;
	}

	function _mint(address to, uint256 id, uint256 subaccount, uint256 amount) internal {
		_mintInternal(to, HashLib.hash(id, subaccount), amount);
	}

	function _burn(address from, uint256 id, uint256 subaccount, uint256 amount) internal {
		_burnInternal(from, HashLib.hash(id, subaccount), amount);
	}

	function _transferFrom(address from, address to, uint256 id, uint256 amount) internal {
		_burn(from, id, 0, amount);
		_mint(to, id, 0, amount);
	}

	function tryFlashTransferFrom(
		address from,
		uint256 fromSubaccount,
		address to,
		uint256 toSubaccount,
		TokenOp[] calldata ops
	) public returns (bool isFlash) {
		FlashSession session = getCurrentSession(false);
		isFlash = FlashSession.unwrap(session) != 0;
		if (isFlash)
			_flashTransferFrom(session, from, fromSubaccount, to, toSubaccount, ops);
		else
			transferFrom(from, fromSubaccount, to, toSubaccount, ops);
	}

	function transferFrom(
		address from,
		uint256 fromSubaccount,
		address to,
		uint256 toSubaccount,
		TokenOp[] calldata ops
	) public returns (bool) {
		bool check = msg.sender != from;
		if (check)
			check = !isOperator[from][msg.sender];

		for (uint256 i = 0; i < ops.length; i++) {
			TokenOp calldata op = ops[i];
			(uint256 id, uint256 amount) = (op.tokenId, op.amount);
			if (check)
				_decreaseApproval(from, id, amount);
			_burn(from, id, fromSubaccount, amount);
			_mint(to, id, toSubaccount, amount);
		}

		return true;
	}

	function _flashTransferFrom(
		FlashSession session,
		address from,
		uint256 fromSubaccount,
		address to,
		uint256 toSubaccount,
		TokenOp[] calldata ops
	) internal {
		bool check = msg.sender != from;
		if (check)
			check = !isOperator[from][msg.sender];

		(FlashUserSession fromSession, UserClue fromClue) =
			initializeUserSession(session, from);

		// can't cache two clues for the same user, so we have to consider cases
		if (from != to) {
			(FlashUserSession toSession, UserClue toClue) =
				initializeUserSession(session, to);

			for (uint256 i = 0; i < ops.length; i++) {
				TokenOp calldata op = ops[i];
				(uint256 id, uint256 amount) = (op.tokenId, op.amount);
				if (check)
					_decreaseApproval(from, id, amount);

				fromClue = addUserDebitWithClue(fromSession, fromClue, fromSubaccount, id, amount);
				toClue = addUserCreditWithClue(toSession, toClue, toSubaccount, id, amount);
			}

			saveUserClue(toSession, toClue);
		} else {
			for (uint256 i = 0; i < ops.length; i++) {
				TokenOp calldata op = ops[i];
				(uint256 id, uint256 amount) = (op.tokenId, op.amount);
				if (check)
					_decreaseApproval(from, id, amount);

				fromClue = addUserDebitWithClue(fromSession, fromClue, fromSubaccount, id, amount);
				fromClue = addUserCreditWithClue(fromSession, fromClue, toSubaccount, id, amount);
			}
		}
		saveUserClue(fromSession, fromClue);
	}

	function flashTransferFrom(
		address from,
		uint256 fromSubaccount,
		address to,
		uint256 toSubaccount,
		TokenOp[] calldata ops
	) public returns (bool) {
		FlashSession session = getCurrentSession(true);
		_flashTransferFrom(session, from, fromSubaccount, to, toSubaccount, ops);
		return true;
	}

	function subaccountFlashTransfer(uint256 from, uint256 to, TokenOp[] calldata ops) public returns (bool) {
		return flashTransferFrom(msg.sender, from, msg.sender, to, ops);
	}

	function _decreaseApproval(address sender, uint256 id, uint256 amount) internal {
		uint256 allowed = allowance[sender][msg.sender][id];
		if (allowed != type(uint256).max)
			allowance[sender][msg.sender][id] = allowed - amount;
	}

	function transfer(address receiver, uint256 id, uint256 amount) public returns (bool) {
		_transferFrom(msg.sender, receiver, id, amount);

		return true;
	}

	function transfer(address to, TokenOp[] calldata ops) public returns (bool) {
		for (uint256 i = 0; i < ops.length; i++) {
			TokenOp calldata op = ops[i];
			(uint256 id, uint256 amount) = (op.tokenId, op.amount);
			_transferFrom(msg.sender, to, id, amount);
		}

		return true;
	}

	function transferFrom(
		address from,
		address to,
		uint256 id,
		uint256 amount
	) public returns (bool) {
		if (msg.sender != from && !isOperator[from][msg.sender])
			_decreaseApproval(from, id, amount);
		_transferFrom(from, to, id, amount);

		return true;
	}

	function approve(address spender, uint256 id, uint256 amount) public returns (bool) {
		allowance[msg.sender][spender][id] = amount;

		return true;
	}

	function setOperator(address operator, bool approved) public returns (bool) {
		isOperator[msg.sender][operator] = approved;

		return true;
	}

	function cook(address realizer, BlueprintCall[] calldata calls) external {
		(FlashSession session, MainClue mainClue) = openFlashAccounting(realizer);

		uint256 len = calls.length;
		for (uint256 k = 0; k < len; k++)
			_flashCook(calls[k], session);

		closeFlashAccounting(mainClue, session);
	}

	function cook(BlueprintCall[] calldata calls) external {
		FlashSession session = getCurrentSession(true);

		uint256 len = calls.length;
		for (uint256 k = 0; k < len; k++)
			_flashCook(calls[k], session);
	}

	function _executeAction(BlueprintCall calldata call) internal {
		// optimistically ask for execution
		IBlueprint(call.blueprint).executeAction(call.action);

		if (call.checksum != 0) {
			// we read mint, burn, give, take directly from returndata
			bytes32 expected = hashActionResults();
			if (call.checksum != expected)
				revert InvalidChecksum();
		}
	}

	function _flashCook(BlueprintCall calldata call, FlashSession session) internal {
		address blueprint = call.blueprint;

		bool checkApprovals;
		address sender = call.sender;
		uint256 subaccount = call.subaccount;
		if (sender == address(0)) {
			// no override
			sender = msg.sender;
		} else if (sender != msg.sender && !isOperator[sender][msg.sender]) {
			checkApprovals = true;
		}

		_executeAction(call);

		(FlashUserSession senderSession, UserClue senderClue) =
			initializeUserSession(session, sender);

		(CalldataTokenOpArray arr, uint256 length) = getTokenOpArray(0x20);
		for (uint256 i = 0; i < length; i++) {
			(uint256 tokenId, uint256 amount) = arr.at(i);
			tokenId = HashLib.hash(blueprint, tokenId);
			senderClue = addUserCreditWithClue(senderSession, senderClue, subaccount, tokenId, amount);
		}

		(arr, length) = getTokenOpArray(0x40);
		for (uint256 i = 0; i < length; i++) {
			(uint256 tokenId, uint256 amount) = arr.at(i);
			tokenId = HashLib.hash(blueprint, tokenId);
			if (checkApprovals)
				_decreaseApproval(sender, tokenId, amount);

			senderClue = addUserDebitWithClue(senderSession, senderClue, subaccount, tokenId, amount);
		}

		(arr, length) = getTokenOpArray(0x60);
		(CalldataTokenOpArray takeArr, uint256 takeLength) = getTokenOpArray(0x80);
		if (blueprint != sender && (length != 0 || takeLength != 0)) {
			uint256 blueprintSubaccount = getSubaccount();
			(FlashUserSession blueprintSession, UserClue blueprintClue) =
				initializeUserSession(session, blueprint);

			for (uint256 i = 0; i < length; i++) {
				(uint256 tokenId, uint256 amount) = arr.at(i);
				senderClue = addUserCreditWithClue(senderSession, senderClue, subaccount, tokenId, amount);
				blueprintClue = addUserDebitWithClue(blueprintSession, blueprintClue, blueprintSubaccount, tokenId, amount);
			}

			for (uint256 i = 0; i < takeLength; i++) {
				(uint256 tokenId, uint256 amount) = takeArr.at(i);
				if (checkApprovals)
					_decreaseApproval(sender, tokenId, amount);

				senderClue = addUserDebitWithClue(senderSession, senderClue, subaccount, tokenId, amount);
				blueprintClue = addUserCreditWithClue(blueprintSession, blueprintClue, blueprintSubaccount, tokenId, amount);
			}
			saveUserClue(blueprintSession, blueprintClue);
		}
		saveUserClue(senderSession, senderClue);
	}

	function credit(uint256 id, uint256 amount) external {
		FlashSession session = getCurrentSession(true);

		(FlashUserSession userSession, UserClue userClue) =
			initializeUserSession(session, msg.sender);

		UserClue newUserClue = addUserDebitWithClue(userSession, userClue, 0, id, amount);
		if (UserClue.unwrap(userClue) != UserClue.unwrap(newUserClue))
			saveUserClue(userSession, newUserClue);
		_mint(msg.sender, id, 0, amount);
	}

	function credit(TokenOp[] calldata ops) external {
		FlashSession session = getCurrentSession(true);

		(FlashUserSession userSession, UserClue userClue) =
			initializeUserSession(session, msg.sender);

		uint256 len = ops.length;
		for (uint256 i = 0; i < len; i++) {
			TokenOp calldata op = ops[i];
			uint256 id = op.tokenId;
			uint256 amount = op.amount;
			userClue = addUserDebitWithClue(userSession, userClue, 0, id, amount);
			_mint(msg.sender, id, 0, amount);
		}
		saveUserClue(userSession, userClue);
	}

	// todo: is this function useful at all?
	function debit(uint256 id, uint256 amount) external {
		FlashSession session = getCurrentSession(true);

		(FlashUserSession userSession, UserClue userClue) =
			initializeUserSession(session, msg.sender);

		UserClue newUserClue = addUserCreditWithClue(userSession, userClue, 0, id, amount);
		if (UserClue.unwrap(userClue) != UserClue.unwrap(newUserClue))
			saveUserClue(userSession, newUserClue);
		_burn(msg.sender, id, 0, amount);
	}

	// todo: is this function useful at all?
	function debit(TokenOp[] calldata ops) external {
		FlashSession session = getCurrentSession(true);

		(FlashUserSession userSession, UserClue userClue) =
			initializeUserSession(session, msg.sender);

		uint256 len = ops.length;
		for (uint256 i = 0; i < len; i++) {
			TokenOp calldata op = ops[i];
			uint256 id = op.tokenId;
			uint256 amount = op.amount;
			userClue = addUserCreditWithClue(userSession, userClue, 0, id, amount);
			_burn(msg.sender, id, 0, amount);
		}
		saveUserClue(userSession, userClue);
	}

	function mint(address to, uint256 tokenId, uint256 amount) external {
		_mint(to, HashLib.hash(msg.sender, tokenId), 0, amount);
	}

	function mint(address to, uint256 toSubaccount, uint256 tokenId, uint256 amount) external {
		_mint(to, HashLib.hash(msg.sender, tokenId), toSubaccount, amount);
	}

	function mint(address to, TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_mint(to, HashLib.hash(msg.sender, ops[i].tokenId), 0, ops[i].amount);
	}

	function mint(address to, uint256 toSubaccount, TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_mint(to, HashLib.hash(msg.sender, ops[i].tokenId), toSubaccount, ops[i].amount);
	}

	function burn(uint256 tokenId, uint256 amount) external {
		_burn(msg.sender, HashLib.hash(msg.sender, tokenId), 0, amount);
	}

	function burn(uint256 subaccount, uint256 tokenId, uint256 amount) external {
		_burn(msg.sender, HashLib.hash(msg.sender, tokenId), subaccount, amount);
	}

	function burn(TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_burn(msg.sender, HashLib.hash(msg.sender, ops[i].tokenId), 0, ops[i].amount);
	}

	function burn(uint256 subaccount, TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_burn(msg.sender, HashLib.hash(msg.sender, ops[i].tokenId), subaccount, ops[i].amount);
	}
}
