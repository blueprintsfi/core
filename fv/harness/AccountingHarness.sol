// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AccountingLib} from "../../src/libraries/AccountingLib.sol";

contract AccountingHarness {
	function addFlashValue(uint256 slotPreimage, uint256 amount) external {
		uint256 slot = hash(slotPreimage);
		AccountingLib.addFlashValue(slot, amount);
	}

	function subtractFlashValue(uint256 slotPreimage, uint256 amount) external {
		uint256 slot = hash(slotPreimage);
		AccountingLib.subtractFlashValue(slot, amount);
	}

	function mint(uint256 slotPreimage, uint256 amount) external {
		uint256 slot = hash(slotPreimage);
		AccountingLib._mintInternal(slot, amount);
	}

	function burn(uint256 slotPreimage, uint256 amount) external {
		uint256 slot = hash(slotPreimage);
		AccountingLib._burnInternal(slot, amount);
	}

	function readAndNullifyFlashValue(uint256 slotPreimage) external {
		uint256 slot = hash(slotPreimage);
		AccountingLib.readAndNullifyFlashValue(slot, slot);
	}

	function balanceOf(uint256 slotPreimage) external returns (uint256) {
		uint256 slot = hash(slotPreimage);
		return AccountingLib.balanceOf(slot);
	}

	function hash(uint256 val) internal pure returns (uint256 res) {
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

	function extsload(uint256 slot) external view returns (uint256 val) {
		assembly {
			val := sload(slot)
		}
	}
}
