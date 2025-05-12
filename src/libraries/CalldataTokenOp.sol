// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

type CalldataTokenOpArray is uint256;

function getTokenOpArray(uint256 pos) pure returns (CalldataTokenOpArray arr, uint256 len) {
	assembly ("memory-safe") {
		returndatacopy(0, pos, 0x20)
		arr := mload(0)
		returndatacopy(0, arr, 0x20)
		len := mload(0)
		arr := add(arr, 0x20)
	}
}

function at(CalldataTokenOpArray arr, uint256 pos) pure returns (uint256 tokenId, uint256 amount) {
	assembly ("memory-safe") {
		returndatacopy(0, add(arr, shl(6, pos)), 0x40)
		tokenId := mload(0)
		amount := mload(0x20)
	}
}

function hashActionResults() pure returns (bytes32 res) {
	assembly ("memory-safe") {
		let ptr := mload(0x40)
		let initPtr := ptr
		returndatacopy(ptr, 0, 0x80)

		for {let scratch := add(ptr, 0x80)} lt(ptr, scratch) {ptr := add(ptr, 0x20)} {
			let retPtr := mload(ptr)
			returndatacopy(scratch, retPtr, 0x20)
			// multiply length 64 times because structs use two words
			let byteLen := shl(6, mload(scratch))
			// now it points to the data, not length
			retPtr := add(retPtr, 0x20)
			returndatacopy(scratch, retPtr, byteLen)
			mstore(ptr, keccak256(scratch, byteLen))
		}

		res := keccak256(initPtr, 0x80)
	}
}
