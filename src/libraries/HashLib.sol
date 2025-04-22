// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library HashLib {
	function hash(address addr, uint256 val) internal pure returns (uint256 res) {
		assembly ("memory-safe") {
			mstore(0, addr)
			mstore(0x20, val)

			res := keccak256(0x0c, 0x34)
		}
	}

	function hash(uint256 val0, uint256 val1) internal pure returns (uint256 res) {
		assembly ("memory-safe") {
			mstore(0, val0)
			mstore(0x20, val1)

			res := keccak256(0, 0x40)
		}
	}

	function hashActionResults() internal pure returns (bytes32 res) {
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
}
