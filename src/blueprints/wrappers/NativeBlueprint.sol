// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";

contract NativeBlueprint is BasicBlueprint {
    error NativeTransferFailed();

    constructor(IBlueprintManager _blueprintManager) BasicBlueprint(_blueprintManager) {}

    function executeAction(bytes calldata action)
        external
        onlyManager
        returns (
            TokenOp[] memory, /*mint*/
            TokenOp[] memory, /*burn*/
            TokenOp[] memory, /*give*/
            TokenOp[] memory /*take*/
        )
    {
        (address to, uint256 amount) = abi.decode(action, (address, uint256));

        (bool success,) = to.call{value: amount}("");
        if (!success) {
            revert NativeTransferFailed();
        }

        return (zero(), oneOperationArray(0, amount), zero(), zero());
    }

    function mint(address to) public payable {
        blueprintManager.mint(to, 0, msg.value);
    }
}
