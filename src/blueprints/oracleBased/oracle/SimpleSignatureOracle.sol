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
		bytes32 payload = bytes32(HashLib.hash(uint256(feedId), response));

		require(ecrecover(payload, v, r, s) == signer);
		return response;
	}
}
