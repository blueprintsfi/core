// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {FlashAccountingLib as Flash} from "../../src/libraries/FlashAccountingLib.sol";

contract FlashAccountingHarness {
	function addFlashValue(uint256 slotPreimage, uint256 amount) external {
		uint256 slot = hash(slotPreimage);
		Flash.addFlashValue(slot, amount);
	}

	function subtractFlashValue(uint256 slotPreimage, uint256 amount) external {
		uint256 slot = hash(slotPreimage);
		Flash.subtractFlashValue(slot, amount);
	}

	function readAndNullifyFlashValue(uint256 slotPreimage) external returns (uint256 positive, uint256 negative) {
		uint256 slot = hash(slotPreimage);
		return Flash.readAndNullifyFlashValue(slot);
	}

	function hash(uint256 val) public pure returns (uint256 res) {
		assembly ("memory-safe") {
			mstore(0, val)
			res := keccak256(0, 0x20)
		}
	}

	function exttload(uint256 slot) external view returns (uint256 val) {
		assembly {
			val := tload(slot)
		}
	}
}
