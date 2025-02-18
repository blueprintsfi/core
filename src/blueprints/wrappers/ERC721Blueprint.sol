// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";
import {HashLib} from "../../libraries/HashLib.sol";
import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";

contract ERC721Blueprint is BasicBlueprint, ERC721TokenReceiver {
	constructor(IBlueprintManager manager) BasicBlueprint(manager) {}

	function onERC721Received(
		address /*operator*/,
		address from,
		uint256 tokenId,
		bytes calldata data
	) external override returns (bytes4) {
		// mint to the owner of the NFT, unless overridden
		address to = from;
		if (data.length != 0)
			to = abi.decode(data, (address));

		// getTokenId is used to simply hash address and uint256,
		// not to be confused to be getting the blueprint manager's id
		blueprintManager.mint(to, HashLib.getTokenId(msg.sender, tokenId), 1);

		return ERC721TokenReceiver.onERC721Received.selector;
	}

	function executeAction(bytes calldata action) external onlyManager returns (
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		(address erc721, address to, uint256 id) =
			abi.decode(action, (address, address, uint256));

		ERC721(erc721).transferFrom(address(this), to, id);

		return (
			zero(),
			oneOperationArray(HashLib.getTokenId(erc721, id), 1),
			zero(),
			zero()
		);
	}
}
