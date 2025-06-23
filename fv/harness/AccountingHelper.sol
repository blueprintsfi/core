// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract AccountingHelper {
	function hash(uint256 val) public pure returns (uint256 res) {
		assembly ("memory-safe") {
			mstore(0, val)
			res := keccak256(0, 0x20)
		}
	}

	function getFirstArg() public payable returns (uint256 val) {
		assembly {
			val := calldataload(0x04)
		}
	}

	function getSecondArg() public payable returns (uint256 val) {
		assembly {
			val := calldataload(0x24)
		}
	}
}
