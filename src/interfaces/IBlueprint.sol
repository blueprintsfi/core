// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TokenOp} from "./IBlueprintManager.sol";

/**
 * @title Blueprint's Interface
 * @author Czar102
 */
interface IBlueprint {
    /// @notice executes an action in Blueprint
    /// @param action a description of the action being taken
    function executeAction(bytes calldata action)
        external
        returns (TokenOp[] memory mint, TokenOp[] memory burn, TokenOp[] memory give, TokenOp[] memory take);
}
