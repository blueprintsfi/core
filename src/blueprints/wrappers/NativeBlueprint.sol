// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager, zero, oneOpArray} from "../BasicBlueprint.sol";

contract NativeBlueprint is BasicBlueprint {
	error NativeTransferFailed();

	constructor(IBlueprintManager _manager) BasicBlueprint(_manager) {}

	function executeAction(bytes calldata action) external onlyManager returns (
		uint256,
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		(address to, uint256 amount) =
			abi.decode(action, (address, uint256));

		(bool success,) = to.call{value: amount}("");
		if (!success)
			revert NativeTransferFailed();

		return (0, zero(), oneOpArray(0, amount), zero(), zero());
	}

	function mint(address to) public payable {
		manager.mint(to, 0, msg.value);
	}
}
