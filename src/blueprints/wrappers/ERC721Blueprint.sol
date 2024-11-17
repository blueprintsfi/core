// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";
import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";

contract ERC721Blueprint is BasicBlueprint, ERC721TokenReceiver {
	error ReentrantDeposit();
	error BalanceOverflow();

	address internal constant registry = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;

	constructor(IBlueprintManager manager) BasicBlueprint(manager) {}

	function executeAction(bytes calldata action) external onlyManager returns (
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		(address erc721, address to, uint nftId) =
			abi.decode(action, (address, address, uint256));

		ERC721(erc721).safeTransferFrom(address(this), to, nftId);

		return (
			zero(),
			oneOperationArray(uint256(uint160(erc721)), 1),
			zero(),
			zero()
		);
	}

	function deposit(address erc721, address to, uint256 nftId) external returns (uint256 deposited) {
		return _deposit(erc721, msg.sender, to, nftId);
	}

	function _deposit(
		address erc721,
		address from,
		address to,
		uint256 nftId
	) internal returns (uint256 deposited) {
		_saveBalance(erc721, _getBalance(erc721));

		ERC721(erc721).safeTransferFrom(from, address(this), nftId);

		return _mintNewNft(erc721, to, nftId);
	}

	function _getBalance(address erc721) internal view returns (uint256) {
		return ERC721(erc721).balanceOf(address(this));
	}

	function _saveBalance(address erc721, uint256 _balance) internal {
		if (_balance == type(uint256).max)
			revert BalanceOverflow();

		assembly {
			// clean potentially dirty bits
			erc721 := shr(96, shl(96, erc721))
			tstore(erc721, add(_balance, 1))
		}
	}

	function _getSavedBalance(address erc721) internal view returns (uint256 _balance) {
		assembly {
			// clean potentially dirty bits
			erc721 := shr(96, shl(96, erc721))
			// make sure that the balance has been saved since this can overflow!
			_balance := sub(tload(erc721), 1)
		}
	}

	function _mintNewNft(address erc721, address to, uint256 nftId) internal returns (uint256) {
		uint256 balance = _getBalance(erc721);

		blueprintManager.mint(to, uint256(uint160(erc721)), 1);
		_saveBalance(erc721, balance);

		return nftId;
	}

	function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return ERC721TokenReceiver.onERC721Received.selector;
    }
}