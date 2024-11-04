// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "./BasicBlueprint.sol";
import {gcd} from "../libraries/Math.sol";

contract BasketBlueprint is BasicBlueprint {
	error LengthsMisaligned();
	error ZeroLength();
	error ZeroAmount();

	constructor(IBlueprintManager manager) BasicBlueprint(manager) {}

	// the onlyManager modifier is removed because it's a pure function
	function executeAction(bytes calldata action) external pure returns (
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		// We use two arrays instead of a single array of structs despite it's
		// less efficient to send these encodings because arrays of structs are
		// horribly inefficient in memory in Solidity – it's actually an array
		// of pointers to structs. Sending the length twice is a lesser evil.
		(bool wrap, uint256[] memory ids, uint256[] memory amounts) =
			abi.decode(action, (bool, uint256[], uint256[]));

		uint256 len = ids.length;
		if (len != amounts.length) revert LengthsMisaligned();
		if (len == 0) revert ZeroLength();

		TokenOp[] memory giveTake = new TokenOp[](len);
		uint256 basket = amounts[0];

		for (uint256 i = 0; i < len; ++i) {
			uint256 amount = amounts[i];
			if (amount == 0) revert ZeroAmount();
			giveTake[i] = TokenOp(ids[i], amount);
			basket = gcd(basket, amount);
		}
		
		for (uint256 i = 0; i < len; i++)
			amounts[i] /= basket;

		uint256 id = uint256(keccak256(abi.encodePacked(_sort(ids), amounts)));
		TokenOp[] memory mintBurn = oneOperationArray(id, basket);


		return wrap ?
			(mintBurn, zero(), zero(), giveTake) :
			(zero(), mintBurn, giveTake, zero());
	}

	function _sort(uint256[] memory arr) private pure returns (uint256[] memory) {
		uint256 len = arr.length;
		for (uint256 i = 0; i < len - 1; ++i) {
			for (uint256 j = 0; j < len - i - 1; ++j) {
				if (arr[j] > arr[j + 1]) {
					(arr[j], arr[j + 1]) = (arr[j + 1], arr[j]);
				}
			}
		}
		return arr;
	}
}
