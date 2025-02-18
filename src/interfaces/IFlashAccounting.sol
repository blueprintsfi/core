// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IFlashAccounting {
	function exttload(uint256 slot) external view returns (uint256 value);
}
