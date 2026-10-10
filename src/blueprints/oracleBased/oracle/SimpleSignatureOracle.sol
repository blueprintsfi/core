// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IOracle} from "./IOracle.sol";
import {HashLib} from "../../../libraries/HashLib.sol";

contract SimpleSignatureOracle is IOracle {
	address immutable signer;

	constructor(address _signer) {
		signer = _signer;
	}

	function getReading(bytes32 feedId, bytes calldata proof) external view returns (uint256) {
		(uint8 v, bytes32 r, bytes32 s, uint256 response) =
			abi.decode(proof, (uint8, bytes32, bytes32, uint256));
		// Scope feedId to this specific oracle contract before hashing in the response,
			// the same way MultisigOracle scopes feedId to its signer-set hash. Without this,
			// the signed payload is just hash(feedId, response) with no binding to which
			// oracle contract it was meant for, so a signature the `signer` key produced for
			// one SimpleSignatureOracle deployment is equally valid on any other deployment
			// (different chain, different consuming protocol, different feed meaning) that
			// happens to receive the same (feedId, response) pair.
			bytes32 scopedFeedId = bytes32(HashLib.hash(address(this), uint256(feedId)));
			bytes32 payload = bytes32(HashLib.hash(uint256(scopedFeedId), response));

		require(ecrecover(payload, v, r, s) == signer);
		return response;
	}

	function getReading(bytes32) external pure returns (uint256) {
		revert();
	}
}
