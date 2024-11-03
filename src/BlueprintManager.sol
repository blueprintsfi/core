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

/// @title @title Blueprint Manager - Advanced Token Management System with Flash Accounting
/// @author Original: @Czar102, Documentation: @DonGuillotine
/// @notice Manages token operations with atomic execution and flash accounting capabilities
/// @dev Implements EIP-6909 token standard with a sophisticated flash accounting system for atomic operations
contract BlueprintManager is IBlueprintManager, FlashAccounting {
	/// @notice Thrown when a blueprint call's checksum doesn't match expected results
    /// @dev Occurs in cook() when the computed hash doesn't match the provided checksum
	error InvalidChecksum();

	/// @notice Thrown when an unauthorized access attempt is made
    /// @dev Used for general access control violations
	error AccessDenied();

	/// @notice Thrown when an unauthorized realization attempt is made
    /// @dev Only the designated realizer can perform certain flash accounting operations
	error RealizeAccessDenied();

	/// @notice Tracks operator approvals for EIP-6909 token operations
    /// @dev Maps (token owner => (operator => approval status))
	mapping(address => mapping(address => bool)) public isOperator;

	/// @notice Tracks token balances for EIP-6909 tokens
    /// @dev Maps (token owner => (token id => balance))
	mapping(address => mapping(uint256 => uint256)) public balanceOf;
	
	/// @notice Tracks token allowances for EIP-6909 token operations
    /// @dev Maps (token owner => (spender => (token id => allowance)))
	mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

	/// @dev Internal mint function for token creation
    /// @param to Address to mint tokens to
    /// @param id Token ID to mint
    /// @param amount Amount of tokens to mint
	/// @custom:accounting Used by both direct minting and flash accounting settlement
	function _mint(address to, uint256 id, uint256 amount) internal override {
		balanceOf[to][id] += amount;
	}

	/// @dev Internal burn function for token destruction
    /// @param from Address to burn tokens from
    /// @param id Token ID to burn
    /// @param amount Amount of tokens to burn
	/// @custom:accounting Used by both direct burning and flash accounting settlement
	function _burn(address from, uint256 id, uint256 amount) internal override {
		balanceOf[from][id] -= amount;
	}

	/// @dev Internal transfer function handling balance updates
    /// @param from Source address
    /// @param to Destination address
    /// @param id Token ID to transfer
    /// @param amount Amount of tokens to transfer
	/// @custom:accounting Handles transfers through burn and mint operations
	function _transferFrom(
		address from,
		address to,
		uint256 id,
		uint256 amount
	) internal {
		_burn(from, id, amount);
		_mint(to, id, amount);
	}

	/// @dev Decreases the approval amount for a spender
    /// @param sender Token owner address
    /// @param id Token ID
    /// @param amount Amount to decrease approval by
    /// @notice Will not decrease if approval is set to max uint256
	/// @custom:security Handles infinite approval case (max uint256)
	function _decreaseApproval(address sender, uint256 id, uint256 amount) internal {
		uint256 allowed = allowance[sender][msg.sender][id];
		if (allowed != type(uint256).max)
			allowance[sender][msg.sender][id] = allowed - amount;
	}

	/// @notice Transfers tokens from sender to specified receiver
    /// @dev Implements EIP-6909 transfer function
    /// @param receiver Address to receive tokens
    /// @param id Token ID to transfer
    /// @param amount Amount of tokens to transfer
    /// @return bool Always returns true (reverts on failure)
	function transfer(
		address receiver,
		uint256 id,
		uint256 amount
	) public virtual returns (bool) {
		_transferFrom(msg.sender, receiver, id, amount);

		return true;
	}

	/// @notice Transfers tokens from a specified sender to a receiver
    /// @dev Implements EIP-6909 transferFrom function with operator support
    /// @param sender Address sending tokens
    /// @param receiver Address receiving tokens
    /// @param id Token ID to transfer
    /// @param amount Amount of tokens to transfer
    /// @return bool Always returns true (reverts on failure)
	function transferFrom(
		address sender,
		address receiver,
		uint256 id,
		uint256 amount
	) public virtual returns (bool) {
		if (msg.sender != sender) {
			if (!isOperator[sender][msg.sender])
				_decreaseApproval(sender, id, amount);
		}

		_transferFrom(sender, receiver, id, amount);

		return true;
	}

	/// @notice Approves spender to transfer tokens on behalf of the sender
    /// @dev Implements EIP-6909 approve function
    /// @param spender Address being approved to spend tokens
    /// @param id Token ID to approve
    /// @param amount Amount of tokens to approve
    /// @return bool Always returns true
	function approve(
		address spender,
		uint256 id,
		uint256 amount
	) public virtual returns (bool) {
		allowance[msg.sender][spender][id] = amount;

		return true;
	}

	/// @notice Sets or revokes operator status for an address
    /// @dev Implements EIP-6909 operator approval
    /// @param operator Address to set operator status for
    /// @param approved True to approve, false to revoke
    /// @return bool Always returns true
	function setOperator(
		address operator,
		bool approved
	) public virtual returns (bool) {
		isOperator[msg.sender][operator] = approved;

		return true;
	}

    /// @notice Executes a batch of blueprint actions atomically
    /// @dev Complex function that:
    ///      1. Opens a flash accounting session with a designated realizer
    ///      2. Processes each blueprint call with proper authorization checks
    ///      3. Handles minting, burning, and transfers through the flash accounting system
    ///      4. Validates results against provided checksums
    ///      5. Maintains accounting clues for atomic settlement
    /// @param realizer Address authorized to realize the flash accounting session
    /// @param calls Array of blueprint calls to execute
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

    /// @notice Credits tokens in the current flash accounting session
    /// @dev Uses transient storage for flash accounting balances
    ///      Only callable by the designated realizer during an active session
    /// @param id Token ID to credit
    /// @param amount Amount to credit
    /// @custom:accounting Updates user's flash accounting balance before minting
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

    /// @notice Batch credits tokens in the current flash accounting session
    /// @dev Processes multiple credit operations atomically
    ///      Uses transient storage for maintaining flash balances
    /// @param ops Array of token operations defining IDs and amounts to credit
    /// @custom:accounting Updates user's flash accounting balances before minting
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

    /// @notice Debits tokens in the current flash accounting session
    /// @dev Uses transient storage for flash accounting balances
    ///      Only callable by the designated realizer during an active session
    /// @param id Token ID to debit
    /// @param amount Amount to debit
	/// @custom:accounting Updates user's flash accounting balance before burning
	// TODO: is this function useful at all?
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

	/// @notice Batch debits tokens in the current flash accounting session
    /// @dev Processes multiple debit operations atomically within a flash accounting session
    ///      Only callable by the designated realizer during an active session
    ///      Uses transient storage to track balance changes before final settlement
    /// @param ops Array of token operations to debit
    /// @custom:accounting Updates flash accounting balances for each operation before burning
	// TODO: is this function useful at all?
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

	/// @notice Mints blueprint-specific tokens
    /// @dev Only callable by the blueprint contract that owns the token ID space
    ///      Token IDs are deterministically generated using HashLib
    ///      No flash accounting is used for direct minting
    /// @param to Recipient address for the minted tokens
    /// @param tokenId Blueprint-specific token ID (will be hashed with msg.sender)
    /// @param amount Amount of tokens to mint
    /// @custom:security Ensures token ID namespacing through msg.sender-based hashing
	function mint(address to, uint256 tokenId, uint256 amount) external {
		_mint(to, HashLib.getTokenId(msg.sender, tokenId), amount);
	}

    /// @notice Batch mints multiple blueprint-specific tokens
    /// @dev Only callable by the blueprint contract that owns the token ID space
    ///      Each token ID is deterministically generated using HashLib
    ///      More gas efficient than multiple single mint operations
    /// @param to Recipient address for all minted tokens
    /// @param ops Array of token operations defining blueprint-specific IDs and amounts
    /// @custom:security Ensures token ID namespacing through msg.sender-based hashing
	function mint(address to, TokenOp[] calldata ops) external {
		uint256 len = ops.length;

		for (uint256 i = 0; i < len; i++)
			_mint(to, HashLib.getTokenId(msg.sender, ops[i].tokenId), ops[i].amount);
	}
}
