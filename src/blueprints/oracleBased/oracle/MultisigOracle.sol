// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IOracle, Response, ConstantOracle} from "./ConstantOracle.sol";
import {HashLib} from "../../../libraries/HashLib.sol";
import {console} from "forge-std/Test.sol";

type ResponseArr is uint256;

library UnsafeResponseArrLib {
	error CacheCallFailed();
	bytes4 constant cacheSelector = bytes4(keccak256("cache((bytes32,uint256)[])"));

	function newResponseArr(Response[] calldata responses) internal pure returns (ResponseArr arr) {
		assembly ("memory-safe") {
			// allocate 0x44 = 68 additional bytes before the array
			arr := add(mload(0x40), 0x44)
			let len := shl(6, responses.length)
			mstore(0x40, add(arr, len))
			// copy `data` from responses, `feedId`s will be rewritten anyway
			calldatacopy(arr, responses.offset, len)
		}
	}

	// the caller has to make sure idx is in bounds
	function at(ResponseArr arr, uint256 idx) internal pure returns (Response memory res) {
		assembly ("memory-safe") {
			res := add(arr, shl(6, idx))
		}
	}

	function hash(ResponseArr arr, uint256 length) internal pure returns (bytes32 res) {
		assembly ("memory-safe") {
			res := keccak256(arr, shl(6, length))
		}
	}

	function cache(ResponseArr arr, ConstantOracle co, uint256 length) internal {
		bool success;
		bytes4 selector = cacheSelector;
		assembly ("memory-safe") {
			arr := sub(arr, 0x44)
			mstore(arr, selector)
			mstore(add(arr, 0x04), 0x20)
			mstore(add(arr, 0x24), length)
			success := call(gas(), co, 0, arr, add(0x44, shl(6, length)), 0, 0)
		}
		if (!success)
			revert CacheCallFailed();
	}
}

using UnsafeResponseArrLib for ResponseArr;

// if the list of signers contains the same address multiple times, it will be
// able to vote multiple times as well
contract MultisigOracle is IOracle {
	ConstantOracle immutable constantOracle;

	error SignatureValidationFailed();

	constructor(ConstantOracle _constantOracle) {
		constantOracle = _constantOracle;
	}

	function cache(
		uint256 threshold,
		address[] calldata signers,
		Response[] calldata responses,
		bytes calldata signatures
	) public {
		bytes32 multisig = getMultisig(threshold, signers);

		ResponseArr arr = UnsafeResponseArrLib.newResponseArr(responses);
		for (uint256 i = 0; i < responses.length; i++) {
			Response memory res = arr.at(i);
			res.feedId = HashLib.hash(multisig, res.feedId);
		}

		bytes32 payload = arr.hash(responses.length);

		// verify signatures
		uint256 idx = 0;
		uint256 ptr = 0;
		uint256 signed = 0;
		unchecked {
			while (idx < signers.length) {
				uint8 v = uint8(signatures[ptr++]);
				if (v < 27) {
					idx += v + 1;
					continue;
				}
				bytes32 r = bytes32(signatures[ptr:]);
				bytes32 s = bytes32(signatures[ptr + 32:]);
				ptr += 64;
				if (signers[idx] != ecrecover(payload, v, r, s))
					revert SignatureValidationFailed();

				signed++;
				idx++;
			}
		}
		if (signed < threshold)
			revert SignatureValidationFailed();

		arr.cache(constantOracle, responses.length);
	}

	function getReading(bytes32 /*feedId*/, bytes calldata /*proof*/) external pure returns (uint256) {
		revert();
	}

	function getReading(bytes32) external pure returns (uint256) {
		revert();
	}

	function getMultisig(uint256 threshold, address[] calldata signers) internal pure returns (bytes32 res) {
		assembly ("memory-safe") {
			let ptr := mload(0x40)
			mstore(ptr, threshold)
			let len := shl(5, signers.length)
			calldatacopy(add(ptr, 0x20), signers.offset, len)
			res := keccak256(ptr, add(len, 0x20))
		}
	}
}
