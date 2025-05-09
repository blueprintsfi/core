// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {FlashAccountingLib as Flash} from "../src/libraries/FlashAccountingLib.sol";

contract FlashAccountingLibTest is Test {
	function setUp() external {}

	function getResult() public returns (uint256 positive, uint256 negative) {
		return Flash.readAndNullifyFlashValue(0);
	}

	function test_correctResult(uint256[] memory add, uint256[] memory subtract) public {
		uint256 i;
		uint256 j;
		while (i != add.length || j != subtract.length) {
			if (vm.randomBool()) {
				if (i == add.length)
					continue;
				Flash.addFlashValue(0, add[i++]);
			} else {
				if (j == subtract.length)
					continue;
				Flash.subtractFlashValue(0, subtract[j++]);
			}

			int val; int preVal;
			assembly {
				val := tload(0)
				preVal := tload(1)
			}
		}

		uint256 _positive;
		uint256 _negative;
		bool _res;
		try this.getResult() returns (uint256 positive, uint256 negative) {
			_res = true;
			_positive = positive;
			_negative = negative;
		} catch {
			console.log("sums were bad");
		}

		(i, j) = (0, 0);
		bool res = true;
		uint256 positive;
		uint256 negative;
		while (i != add.length || j != subtract.length) {
			if (negative == 0 && j != subtract.length) {
				negative += subtract[j++];
			} else if (positive == 0 && i != add.length) {
				positive += add[i++];
			} else if (i != add.length) {
				uint256 temp;
				unchecked {
					temp = positive + add[i++];
					if (temp < positive) {
						res = false;
						break;
					}
					positive = temp;
				}
			} else {
				uint256 temp;
				unchecked {
					temp = negative + subtract[j++];
					if (temp < negative) {
						res = false;
						break;
					}
					negative = temp;
				}
			}

			if (positive < negative) {
				negative -= positive;
				positive -= positive;
			} else {
				positive -= negative;
				negative -= negative;
			}
		}

		assertEq(res, _res, "revert reasons incorrect");
		if (res) {
			assertEq(positive, _positive, "positive incorrect");
			assertEq(negative, _negative, "negative incorrect");
		}
	}
}
