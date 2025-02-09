// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// gcd(0, 0) = 0
function gcd(uint256 a, uint256 b) pure returns (uint256) {
    while (b != 0) {
        (a, b) = (b, a % b);
    }

    return a;
}
