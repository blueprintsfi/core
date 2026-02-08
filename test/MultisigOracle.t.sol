// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {HashLib} from "../src/BlueprintManager.sol";
import {
	ConstantOracle,
	MultisigOracle,
	Response
} from "../src/blueprints/oracleBased/oracle/MultisigOracle.sol";

library BytesLib {
	// gotta make sure the memory after the array is allocated not to overwrite
	// other memory variables
	function append(bytes memory b, bytes memory a) internal pure {
		assembly ("memory-safe") {
			let blen := mload(b)
			let alen := mload(a)
			mcopy(add(add(0x20, b), blen), add(a, 0x20), alen)
			mstore(b, add(blen, alen))
		}
	}

	function create(uint256 length) internal pure returns (bytes memory b) {
		assembly ("memory-safe") {
			b := mload(0x40)
			mstore(0x40, add(b, add(0x20, length)))
			mstore(b, 0)
		}
	}
}

using BytesLib for bytes;

contract MultisigOracleTest is Test {
	mapping (bytes32 internalFeed => bool responded) responded;
	ConstantOracle oracle = new ConstantOracle();
	MultisigOracle moracle = new MultisigOracle(oracle);

	function setUp() external {}

	function testMultisig(uint256 signers, Response[] calldata responses) public {
		vm.assume(signers < 1000);

		uint256 threshold = vm.randomUint(0, signers);
		Response[] memory res = responses;

		address[] memory signersList = new address[](signers);
		for (uint256 i = 0; i < signers; i++) {
			signersList[i] = vm.createWallet(i + 1).addr;
		}

		bytes32 multisig = keccak256(abi.encodePacked(threshold, signersList));
		bytes memory packedResponses = BytesLib.create(64 * res.length);
		for (uint256 i = 0; i < res.length; i++) {
			vm.assume(!responded[res[i].feedId]);
			responded[res[i].feedId] = true;
			res[i].feedId = keccak256(abi.encodePacked(multisig, res[i].feedId));
			packedResponses.append(abi.encodePacked(res[i].feedId, res[i].data));
		}

		bytes32 digest = keccak256(packedResponses);

		bytes memory signatures = BytesLib.create(signers * 65);
		uint256 signed = 0;
		uint256 skipped = 0;
		for (uint256 i = 0; i < signers; i++) {
			if (vm.randomBool()) {
				while (skipped != 0) {
					uint256 skipping = skipped > 27 ? 27 : skipped;
					signatures.append(abi.encodePacked(uint8(skipping - 1)));
					skipped -= skipping;
				}
				(uint8 v, bytes32 r, bytes32 s) = vm.sign(i + 1, digest);
				signatures.append(abi.encodePacked(v, r, s));
				signed++;
			} else {
				skipped++;
			}
		}
		while (skipped != 0) {
			uint skipping = skipped > 26 ? 26 : skipped;
			signatures.append(abi.encodePacked(skipping));
			skipped -= skipping;
		}

		bool failure = signed < threshold;
		if (failure)
			vm.expectRevert(MultisigOracle.SignatureValidationFailed.selector);

		moracle.cache(threshold, signersList, responses, signatures);

		if (!failure) {
			for (uint256 i = 0; i < res.length; i++) {
				bytes32 feed = keccak256(abi.encodePacked(moracle, res[i].feedId));
				vm.assertEq(oracle.getReading(feed), res[i].data);
			}
		}

		// moracle.cache(3, new address[](0), new Response[](0));
	}
}
