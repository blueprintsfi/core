// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

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
	MainClue,
	FlashSession,
	SessionClue
} from "./FlashAccounting.sol";

using { at } for CalldataTokenOpArray;

contract BlueprintManager is FlashAccounting, IBlueprintManager {
	error InvalidChecksum();
	error AccessDenied();
	error InsufficientBalance();

	mapping(address => mapping(address => bool)) public isOperator;
	mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

	function balanceOf(address user, uint256 subaccount, uint256 tokenId) public view returns (uint256) {
		return _balanceOf(user, subaccount, tokenId);
	}

	function balanceOf(address user,uint256 tokenId) public view returns (uint256) {
		return _balanceOf(user, 0, tokenId);
	}

	function _transferFrom(address from, address to, uint256 id, uint256 amount) internal {
		_burn(from, 0, id, amount);
		_mint(to, 0, id, amount);
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
			_burn(from, fromSubaccount, id, amount);
			_mint(to, toSubaccount, id, amount);
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

		SessionClue clue = getSessionClue(session);

		for (uint256 i = 0; i < ops.length; i++) {
			TokenOp calldata op = ops[i];
			(uint256 id, uint256 amount) = (op.tokenId, op.amount);
			if (check)
				_decreaseApproval(from, id, amount);

			clue = addUserDebitWithClue(session, clue, getPtr(from, fromSubaccount, id), amount);
			clue = addUserCreditWithClue(session, clue, getPtr(to, toSubaccount, id), amount);
		}
		saveSessionClue(session, clue);
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

		SessionClue clue = getSessionClue(session);

		(CalldataTokenOpArray arr, uint256 length) = getTokenOpArray(0x20); // mint
		for (uint256 i = 0; i < length; i++) {
			(uint256 id, uint256 amount) = arr.at(i);
			id = HashLib.hash(blueprint, id);
			clue = addUserCreditWithClue(session, clue, getPtr(sender, subaccount, id), amount);
		}

		(arr, length) = getTokenOpArray(0x40); // burn
		for (uint256 i = 0; i < length; i++) {
			(uint256 id, uint256 amount) = arr.at(i);
			id = HashLib.hash(blueprint, id);
			if (checkApprovals)
				_decreaseApproval(sender, id, amount);

			clue = addUserDebitWithClue(session, clue, getPtr(sender, subaccount, id), amount);
		}

		(arr, length) = getTokenOpArray(0x60); // give
		(CalldataTokenOpArray takeArr, uint256 takeLength) = getTokenOpArray(0x80); // take
		if (blueprint != sender && (length != 0 || takeLength != 0)) {
			uint256 blueprintSubaccount = getSubaccount();

			for (uint256 i = 0; i < length; i++) {
				(uint256 id, uint256 amount) = arr.at(i);
				clue = addUserCreditWithClue(session, clue, getPtr(sender, subaccount, id), amount);
				clue = addUserDebitWithClue(session, clue, getPtr(blueprint, blueprintSubaccount, id), amount);
			}

			for (uint256 i = 0; i < takeLength; i++) {
				(uint256 id, uint256 amount) = takeArr.at(i);
				if (checkApprovals)
					_decreaseApproval(sender, id, amount);

				clue = addUserDebitWithClue(session, clue, getPtr(sender, subaccount, id), amount);
				clue = addUserCreditWithClue(session, clue, getPtr(blueprint, blueprintSubaccount, id), amount);
			}
		}
		saveSessionClue(session, clue);
	}

	function credit(uint256 id, uint256 amount) external {
		FlashSession session = getCurrentSession(true);
		SessionClue clue = getSessionClue(session);

		SessionClue newClue = addUserDebitWithClue(session, clue, getPtr(msg.sender, 0, id), amount);
		if (SessionClue.unwrap(clue) != SessionClue.unwrap(newClue))
			saveSessionClue(session, newClue);

		_mint(msg.sender, 0, id, amount);
	}

	function credit(TokenOp[] calldata ops) external {
		FlashSession session = getCurrentSession(true);
		SessionClue clue = getSessionClue(session);

		uint256 len = ops.length;
		for (uint256 i = 0; i < len; i++) {
			TokenOp calldata op = ops[i];
			(uint256 id, uint256 amount) = (op.tokenId, op.amount);
			clue = addUserDebitWithClue(session, clue, getPtr(msg.sender, 0, id), amount);
			_mint(msg.sender, 0, id, amount);
		}
		saveSessionClue(session, clue);
	}

	// todo: is this function useful at all?
	function debit(uint256 id, uint256 amount) external {
		FlashSession session = getCurrentSession(true);
		SessionClue clue = getSessionClue(session);

		SessionClue newClue = addUserCreditWithClue(session, clue, getPtr(msg.sender, 0, id), amount);
		if (SessionClue.unwrap(clue) != SessionClue.unwrap(newClue))
			saveSessionClue(session, newClue);

		_burn(msg.sender, 0, id, amount);
	}

	// todo: is this function useful at all?
	function debit(TokenOp[] calldata ops) external {
		FlashSession session = getCurrentSession(true);
		SessionClue clue = getSessionClue(session);

		uint256 len = ops.length;
		for (uint256 i = 0; i < len; i++) {
			TokenOp calldata op = ops[i];
			(uint256 id, uint256 amount) = (op.tokenId, op.amount);
			clue = addUserCreditWithClue(session, clue, getPtr(msg.sender, 0, id), amount);
			_burn(msg.sender, 0, id, amount);
		}
		saveSessionClue(session, clue);
	}

	function mint(address to, uint256 tokenId, uint256 amount) external {
		_mint(to, 0, HashLib.hash(msg.sender, tokenId), amount);
	}

	function mint(address to, uint256 toSubaccount, uint256 tokenId, uint256 amount) external {
		_mint(to, toSubaccount, HashLib.hash(msg.sender, tokenId), amount);
	}

	function mint(address to, TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_mint(to, 0, HashLib.hash(msg.sender, ops[i].tokenId), ops[i].amount);
	}

	function mint(address to, uint256 toSubaccount, TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_mint(to, toSubaccount, HashLib.hash(msg.sender, ops[i].tokenId), ops[i].amount);
	}

	function burn(uint256 tokenId, uint256 amount) external {
		_burn(msg.sender, 0, HashLib.hash(msg.sender, tokenId), amount);
	}

	function burn(uint256 subaccount, uint256 tokenId, uint256 amount) external {
		_burn(msg.sender, subaccount, HashLib.hash(msg.sender, tokenId), amount);
	}

	function burn(TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_burn(msg.sender, 0, HashLib.hash(msg.sender, ops[i].tokenId), ops[i].amount);
	}

	function burn(uint256 subaccount, TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_burn(msg.sender, subaccount, HashLib.hash(msg.sender, ops[i].tokenId), ops[i].amount);
	}
}
