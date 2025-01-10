// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";
import {HashLib} from "../../libraries/HashLib.sol";
import {ERC1155, ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";

contract ERC1155Blueprint is BasicBlueprint, ERC1155TokenReceiver {
	constructor(IBlueprintManager manager) BasicBlueprint(manager) {}

	function getOperations(
		address erc1155,
		uint256[] memory ids,
		uint256[] memory amounts
	) internal pure returns (TokenOp[] memory ops) {
		ops = new TokenOp[](ids.length);
		for (uint256 i = 0; i < ids.length; i++)
			ops[i] = TokenOp(HashLib.getTokenId(erc1155, ids[i]), amounts[i]);
	}

	function onERC1155Received(
		address /*operator*/,
		address from,
		uint256 id,
		uint256 amount,
		bytes calldata data
	) external override returns (bytes4) {
		// mint to the owner of the NFT, unless overridden
		address to = from;
		if (data.length != 0)
			to = abi.decode(data, (address));

		// getTokenId is used to simply hash address and uint256,
		// not to be confused to be getting the blueprint manager's id
		blueprintManager.mint(to, HashLib.getTokenId(msg.sender, id), amount);

		return ERC1155TokenReceiver.onERC1155Received.selector;
	}

    function onERC1155BatchReceived(
		address /*operator*/,
		address from,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes calldata data
    ) external override returns (bytes4) {
		// mint to the owner of the NFT, unless overridden
		address to = from;
		if (data.length != 0)
			to = abi.decode(data, (address));

		blueprintManager.mint(to, getOperations(msg.sender, ids, amounts));

        return ERC1155TokenReceiver.onERC1155BatchReceived.selector;
    }

	function executeAction(bytes calldata action) 
        external 
        onlyManager 
        returns (
            TokenOp[] memory /* mint */, 
            TokenOp[] memory /* burn */, 
            TokenOp[] memory /* give */, 
            TokenOp[] memory /* take */
        ) 
    {
        address erc1155;
        address to;
        uint256[] calldata ids;
        uint256[] calldata amounts;
        bytes calldata data;

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

        ERC1155(erc1155).safeBatchTransferFrom(address(this), to, ids, amounts, data);

        return (
            zero(),
            getOperations(erc1155, ids, amounts),
            zero(),
            zero()
        );
    }
}
