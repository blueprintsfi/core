// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TokenOp, IBlueprint} from "../interfaces/IBlueprint.sol";
import {IBlueprintManager} from "../interfaces/IBlueprintManager.sol";

abstract contract BasicBlueprint is IBlueprint {
	IBlueprintManager immutable public manager;

	error AccessDenied();

	constructor(IBlueprintManager _manager) {
		manager = _manager;
	}

	modifier onlyManager() {
		if (msg.sender != address(manager))
			revert AccessDenied();

		_;
	}
}

function zero() pure returns (TokenOp[] memory z) {
	assembly ("memory-safe") {
		z := 0x60
	}
}

function oneOpArray(uint256 tokenId, uint256 amount) pure returns (TokenOp[] memory res) {
	assembly ("memory-safe") {
		res := mload(0x40)
		mstore(0x40, add(res, 0x80))

		let structPtr := add(res, 0x40)

		mstore(res, 1)
		mstore(add(res, 0x20), structPtr)
		mstore(structPtr, tokenId)
		mstore(add(res, 0x60), amount)
	}
}
