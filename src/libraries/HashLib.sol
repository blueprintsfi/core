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
}
