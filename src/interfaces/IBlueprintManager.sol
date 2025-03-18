// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IFlashAccounting} from "./IFlashAccounting.sol";

struct TokenOp {
	uint256 tokenId;
	uint256 amount;
}

struct BlueprintCall {
	address sender;
	address blueprint;
	bytes action;
	bytes32 checksum;
}

/// @title BlueprintManager's Interface
/// @author Czar102
interface IBlueprintManager is IFlashAccounting {
	/// @notice executes a series of calls to Blueprints
	/// @param calls the set of calls to be made
	/// @dev must either be the party represented in each of these calls,
	///      or an operator of the calls[i].sender
	function cook(address realizer, BlueprintCall[] calldata calls) external;
	function cook(BlueprintCall[] calldata calls) external;

	/// @notice mints single type tokens according to the TokenOp
	/// @param to the address to mint to
	/// @param tokenId the Blueprint's token id to mint
	/// @param amount the token amount to mint
	/// @dev keep in mind that burning (inverting this action) is only possible
	///       via cook invoked by the user or their operator
	function mint(address to, uint256 tokenId, uint256 amount) external;

	/// @notice mints many types of tokens according to the `ops` array
	/// @param to the address to mint to
	/// @param ops the array of Blueprint's token ids and amounts to mint
	/// @dev keep in mind that burning (inverting this action) is only possible
	///       via cook invoked by the user or their operator
	function mint(address to, TokenOp[] calldata ops) external;

	function isOperator(address user, address operator) external view returns (bool);
	function balanceOf(address user, uint256 tokenId) external view returns (uint256);
	function balanceOf(address user, uint256 subaccount, uint256 tokenId) external view returns (uint256);
	function allowance(address user, address allowed, uint256 tokenId) external view returns (uint256);
	function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
	function transfer(address to, TokenOp[] calldata ops) external returns (bool);
	function transferFrom(address from, address to, uint256 id, uint256 amount) external returns (bool);
	function transferFrom(
		address from,
		uint256 fromSubaccount,
		address to,
		uint256 toSubaccount,
		TokenOp[] calldata ops
	) external returns (bool);
	function flashTransferFrom(
		address from,
		uint256 fromSubaccount,
		address to,
		uint256 toSubaccount,
		TokenOp[] calldata ops
	) external returns (bool);
	function approve(address spender, uint256 id, uint256 amount) external returns (bool);
	function setOperator(address operator, bool approved) external returns (bool);
	function credit(uint256 id, uint256 amount) external;
	function credit(TokenOp[] calldata ops) external;
	function debit(uint256 id, uint256 amount) external;
	function debit(TokenOp[] calldata ops) external;
	function burn(uint256 tokenId, uint256 amount) external ;
	function burn(TokenOp[] calldata ops) external;
}
