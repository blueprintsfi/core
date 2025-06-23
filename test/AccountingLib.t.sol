// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {AccountingLib} from "../src/libraries/AccountingLib.sol";

contract AccountingLibTest is Test {
	function setUp() external {}

	function getResult() public {
		AccountingLib.settleFlashBalance(0, 0);
	}

	function test_correctResult_exists(uint256[] memory add, uint256[] memory subtract) public {
		test_correctResult(add, subtract, true);
	}

	function test_correctResult_doesntExist(uint256[] memory add, uint256[] memory subtract) public {
		test_correctResult(add, subtract, false);
	}

	function test_correctResult(uint256[] memory add, uint256[] memory subtract, bool hasResult) internal {
		AccountingLib._mintInternal(0, type(uint256).max);

		uint256 i;
		uint256 j;
		while (i != add.length || j != subtract.length) {
			if (vm.randomBool()) {
				if (i == add.length)
					continue;
				AccountingLib.addFlashValue(0, add[i++]);
			} else {
				if (j == subtract.length)
					continue;
				AccountingLib.subtractFlashValue(0, subtract[j++]);
			}
		}

		bool _res;
		try this.getResult() {
			_res = true;
		} catch {}

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

		vm.assume(res == hasResult);

		assertTrue(_res || !res, "reverted while it shouldn't");
		if (res) {
			if (negative != 0)
				assertEq(negative, type(uint).max - AccountingLib.balanceOf(0), "negative incorrect");
			else {
				AccountingLib._burnInternal(0, type(uint256).max);
				assertEq(positive, AccountingLib.balanceOf(0), "positive incorrect");
			}
		}
	}
}
