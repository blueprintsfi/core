// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import { HashLib } from "./libraries/HashLib.sol";
import { IBlueprint } from "./interfaces/IBlueprint.sol";
import { IBlueprintManager, TokenOp, BlueprintCall } from "./interfaces/IBlueprintManager.sol";
import {
	FlashAccounting,
	FlashSession,
	MainClue,
	FlashUserSession,
	UserClue
} from "./FlashAccounting.sol";

contract BlueprintManager is IBlueprintManager, FlashAccounting {
	error InvalidChecksum();
	error AccessDenied();
	error RealizeAccessDenied();
	error PermitExpiredDeadline();
	error InvalidSignature();


	/// @notice eip-6909 operator mapping
	mapping(address => mapping(address => bool)) public isOperator;
	/// @notice eip-6909 balance mapping
	mapping(address => mapping(uint256 => uint256)) public balanceOf;
	/// @notice eip-6909 allowance mapping
	mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

	/// @notice Domain separator for EIP-712 signatures
	bytes32 public DOMAIN_SEPARATOR;

	// Struct and type hashes for EIP-712 permit function
	bytes32 public constant APPROVAL_TYPEHASH = keccak256(
		"Permit(address owner,address spender,uint256 id,uint256 amount,uint256 nonce,uint256 deadline)"
	);
	bytes32 public constant OPERATOR_TYPEHASH = keccak256(
		"PermitOperator(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)"
	);

	uint256 public chainId;

	mapping(address => uint256) public approval_nonces;
	mapping(address => uint256) public operator_nonces;

	constructor() {
		assembly {
			chainId := chainId()
		}
		DOMAIN_SEPARATOR = keccak256(
			abi.encode(
				keccak256(
					"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
				),
				keccak256(bytes("BlueprintManager")),
				keccak256(bytes("1")),
				chainId,
				address(this)
			)
		);
	}

	function _mint(address to, uint256 id, uint256 amount) internal override {
		balanceOf[to][id] += amount;
	}

	function _burn(address from, uint256 id, uint256 amount) internal override {
		balanceOf[from][id] -= amount;
	}

	function _transferFrom(
		address from,
		address to,
		uint256 id,
		uint256 amount
	) internal {
		_burn(from, id, amount);
		_mint(to, id, amount);
	}

	function _decreaseApproval(address sender, uint256 id, uint256 amount) internal {
		uint256 allowed = allowance[sender][msg.sender][id];
		if (allowed != type(uint256).max)
			allowance[sender][msg.sender][id] = allowed - amount;
	}

	/**
	 * @notice transfers `amount` of token `id` to `receiver`
	 * @dev reverts on failure
	 * @return is always true if didn't revert
	 */
	function transfer(
		address receiver,
		uint256 id,
		uint256 amount
	) public virtual returns (bool) {
		_transferFrom(msg.sender, receiver, id, amount);

		return true;
	}

	function transferFrom(
		address sender,
		address receiver,
		uint256 id,
		uint256 amount
	) public virtual returns (bool) {
		if (msg.sender != sender && !isOperator[sender][msg.sender])
			_decreaseApproval(sender, id, amount);

		_transferFrom(sender, receiver, id, amount);

		return true;
	}

	function approve(
		address spender,
		uint256 id,
		uint256 amount
	) public virtual returns (bool) {
		allowance[msg.sender][spender][id] = amount;

		return true;
	}

	function setOperator(
		address operator,
		bool approved
	) public virtual returns (bool) {
		isOperator[msg.sender][operator] = approved;

		return true;
	}

	function checkChainId() internal {
		uint256 nowChainId;
		assembly {
			nowChainId := chainId()
		}

		if(chainId != nowChainId) {
			chainId = nowChainId;
			
			DOMAIN_SEPARATOR = keccak256(
				abi.encode(
					keccak256(
						"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
					),
					keccak256(bytes("BlueprintManager")),
					keccak256(bytes("1")),
					chainId,
					address(this)
				)
			);
		}
	}

	//EIP-712 permit function for approvals
	function permit(
		address owner,
		address spender,
		uint256 id,
		uint256 amount,
		uint256 deadline,
		uint8 v,
		bytes32 r,
		bytes32 s
	) external {
		if(block.timestamp > deadline) 
			revert PermitExpiredDeadline();

		bytes32 structHash = keccak256(
			abi.encode(
				APPROVAL_TYPEHASH,
				owner,
				spender,
				id,
				amount,
				approval_nonces[owner]++,
				deadline
			)
		);

		checkChainId();

		bytes32 hash = keccak256(
			abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
		);

		address signer = ecrecover(hash, v, r, s);
		if (signer == address(0) || signer != owner)
			revert InvalidSignature();

		allowance[owner][spender][id] = amount;
	}

	function permitOperator(
		address owner,
		address operator,
		bool approved,
		uint256 deadline,
		uint8 v,
		bytes32 r,
		bytes32 s
	) external {
		if(block.timestamp > deadline) 
			revert PermitExpiredDeadline();

		bytes32 structHash = keccak256(
			abi.encode(
				OPERATOR_TYPEHASH,
				owner,
				operator,
				approved,
				operator_nonces[owner]++,
				deadline
			)
		);

		checkChainId();

		bytes32 hash = keccak256(
			abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
		);

		address signer = ecrecover(hash, v, r, s);
		if (signer == address(0) || signer != owner)
			revert InvalidSignature();

		isOperator[owner][operator] = approved;
	}

	function cook(
		address realizer,
		BlueprintCall[] calldata calls
	) external {
		uint256 len = calls.length;

		(FlashSession session, MainClue mainClue) = openFlashAccounting(realizer);

		for (uint256 k = 0; k < len; k++) {
			BlueprintCall calldata call = calls[k];
			address blueprint = call.blueprint;

			bool checkApprovals;
			address sender = call.sender;
			if (sender == address(0)) {
				// no override
				sender = msg.sender;
			} else if (sender != msg.sender && !isOperator[sender][msg.sender]) {
				checkApprovals = true;
			}

			// optimistically ask for execution
			(
				TokenOp[] memory mint,
				TokenOp[] memory burn,
				TokenOp[] memory give,
				TokenOp[] memory take
			) = IBlueprint(blueprint).executeAction(call.action);

			if (call.checksum != 0) {
				// we read mint, burn, give, take directly from returndata
				bytes32 expected = HashLib.hashActionResults();

				if (call.checksum != expected)
					revert InvalidChecksum();
			}

			(FlashUserSession senderSession, UserClue senderClue) =
				initializeUserSession(session, sender);

			for (uint256 i = 0; i < mint.length; i++) {
				senderClue = addUserCreditWithClue(
					senderSession,
					senderClue,
					HashLib.getTokenId(blueprint, mint[i].tokenId),
					mint[i].amount
				);
			}

			for (uint256 i = 0; i < burn.length; i++) {
				uint256 tokenId = HashLib.getTokenId(blueprint, burn[i].tokenId);
				uint256 amount = burn[i].amount;

				if (checkApprovals)
					_decreaseApproval(sender, tokenId, amount);

				senderClue = addUserDebitWithClue(senderSession, senderClue, tokenId, amount);
			}

			if (blueprint != sender && (give.length != 0 || take.length != 0)) {
				(FlashUserSession blueprintSession, UserClue blueprintClue) =
					initializeUserSession(session, blueprint);

				for (uint256 i = 0; i < give.length; i++) {
					uint256 id = give[i].tokenId;
					uint256 amount = give[i].amount;
					senderClue = addUserCreditWithClue(senderSession, senderClue, id, amount);
					blueprintClue = addUserDebitWithClue(blueprintSession, blueprintClue, id, amount);
				}

				for (uint256 i = 0; i < take.length; i++) {
					uint256 id = take[i].tokenId;
					uint256 amount = take[i].amount;

					if (checkApprovals)
						_decreaseApproval(sender, id, amount);

					senderClue = addUserDebitWithClue(senderSession, senderClue, id, amount);
					blueprintClue = addUserCreditWithClue(blueprintSession, blueprintClue, id, amount);
				}
				saveUserClue(blueprintSession, blueprintClue);
			}
			saveUserClue(senderSession, senderClue);
		}

		closeFlashAccounting(mainClue, session);
	}

	function credit(uint256 id, uint256 amount) external {
		(FlashSession session, address realizer) = getCurrentSessionAndRealizer();

		if (realizer != address(0) && realizer != msg.sender)
			revert RealizeAccessDenied();

		(FlashUserSession userSession, UserClue userClue) =
			initializeUserSession(session, msg.sender);

		UserClue newUserClue = addUserDebitWithClue(userSession, userClue, id, amount);
		if (UserClue.unwrap(userClue) != UserClue.unwrap(newUserClue))
			saveUserClue(userSession, newUserClue);
		_mint(msg.sender, id, amount);
	}

	function credit(TokenOp[] calldata ops) external {
		(FlashSession session, address realizer) = getCurrentSessionAndRealizer();

		if (realizer != address(0) && realizer != msg.sender)
			revert RealizeAccessDenied();

		(FlashUserSession userSession, UserClue userClue) =
			initializeUserSession(session, msg.sender);

		uint256 len = ops.length;
		for (uint256 i = 0; i < len; i++) {
			TokenOp calldata op = ops[i];
			uint256 id = op.tokenId;
			uint256 amount = op.amount;
			userClue = addUserDebitWithClue(userSession, userClue, id, amount);
			_mint(msg.sender, id, amount);
		}
		saveUserClue(userSession, userClue);
	}

	// todo: is this function useful at all?
	function debit(uint256 id, uint256 amount) external {
		(FlashSession session, address realizer) = getCurrentSessionAndRealizer();

		if (realizer != address(0) && realizer != msg.sender)
			revert RealizeAccessDenied();

		(FlashUserSession userSession, UserClue userClue) =
			initializeUserSession(session, msg.sender);

		UserClue newUserClue = addUserCreditWithClue(userSession, userClue, id, amount);
		if (UserClue.unwrap(userClue) != UserClue.unwrap(newUserClue))
			saveUserClue(userSession, newUserClue);
		_burn(msg.sender, id, amount);
	}

	// todo: is this function useful at all?
	function debit(TokenOp[] calldata ops) external {
		(FlashSession session, address realizer) = getCurrentSessionAndRealizer();

		if (realizer != address(0) && realizer != msg.sender)
			revert RealizeAccessDenied();

		(FlashUserSession userSession, UserClue userClue) =
			initializeUserSession(session, msg.sender);

		uint256 len = ops.length;
		for (uint256 i = 0; i < len; i++) {
			TokenOp calldata op = ops[i];
			uint256 id = op.tokenId;
			uint256 amount = op.amount;
			userClue = addUserCreditWithClue(userSession, userClue, id, amount);
			_burn(msg.sender, id, amount);
		}
		saveUserClue(userSession, userClue);
	}

	function mint(address to, uint256 tokenId, uint256 amount) external {
		_mint(to, HashLib.getTokenId(msg.sender, tokenId), amount);
	}

	function mint(address to, TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_mint(to, HashLib.getTokenId(msg.sender, ops[i].tokenId), ops[i].amount);
	}
}
