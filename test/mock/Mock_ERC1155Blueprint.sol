// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../../src/blueprints/BasicBlueprint.sol";
import {HashLib} from "../../src/libraries/HashLib.sol";
import {ERC1155, ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";

import "forge-std/console.sol"; 

contract Mock_ERC1155Blueprint is BasicBlueprint, ERC1155TokenReceiver {
	constructor(IBlueprintManager manager) BasicBlueprint(manager) {}

	function executeAction(bytes calldata action) 
        external 
        onlyManager 
        returns (
            TokenOp[] memory /* mint */, 
            TokenOp[] memory /* burn */, 
            TokenOp[] memory /* give */, 
            TokenOp[] memory /* take */
        ) {}
	function executeActionNew(bytes calldata action) 
        external 
        pure
        returns (
            address erc1155,
            address to,
            uint256[] calldata ids,
            uint256[] calldata amounts,
            bytes calldata data
        ) 
    {
        assembly {            
            erc1155 := calldataload(action.offset)
            
            to := calldataload(add(action.offset, 0x20))
            
            ids.offset := add(add(action.offset, calldataload(add(action.offset, 0x40))), 0x20)
            ids.length := calldataload(add(action.offset, calldataload(add(action.offset, 0x40))))
            
            amounts.offset := add(add(action.offset, calldataload(add(action.offset, 0x60))), 0x20)
            amounts.length := 
                calldataload(add(action.offset, calldataload(add(action.offset, 0x60))))

            data.offset := add(add(action.offset, calldataload(add(action.offset, 0x80))), 0x20)
            data.length := calldataload(add(action.offset, calldataload(add(action.offset, 0x80))))
        }
    }
	function executeActionOld(bytes calldata action) external pure returns (
        address erc1155,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
	) {
		(erc1155, to, ids, amounts, data) =
			abi.decode(action, (address, address, uint256[], uint256[], bytes));
	}
}
