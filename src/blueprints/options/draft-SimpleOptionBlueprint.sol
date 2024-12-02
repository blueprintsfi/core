// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";
import {gcd} from "../../libraries/Math.sol";

contract SimpleOptionBlueprint is BasicBlueprint {
	mapping (uint256 baseId => uint256 count) reserves;

	constructor(IBlueprintManager manager) BasicBlueprint(manager) {}

	function executeAction(bytes calldata action) external onlyManager returns (
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		(
			uint256 token0,
			uint256 token1,
			uint256 num,
			uint256 denom,
			uint256 expiry,
			uint256 settlement,
			address settler,
			bool mint
		) = abi.decode(
			action,
			(uint256, uint256, uint256, uint256, uint256, uint256, address, bool)
		);

		TokenOp[] memory giveTake = oneOperationArray(token0, num);

		uint256 count = gcd(num, denom);
		(num, denom) = (num / count, denom / count);

		bool swap;
		if (swap = token1 > token0) {
			(token0, token1) = (token1, token0);
			(num, denom) = (denom, num);
		}

		uint256 baseId = uint256(keccak256(
			abi.encodePacked(token0, token1, num, denom, expiry, settlement, settler)
		));

		TokenOp[] memory mintBurn = new TokenOp[](2);
		unchecked {
			// short option
			mintBurn[0] = TokenOp(baseId + 2, count);
			// now the baseId will be the call/put
			if (swap)
				baseId++;
			mintBurn[1] = TokenOp(baseId, count);
		}

		if (mint)
			reserves[baseId] += count;
		else // underflow check prevents from going beyond reserves
			reserves[baseId] -= count;

		return mint ?
			(mintBurn, zero(), zero(), giveTake) :
			(zero(), mintBurn, giveTake, zero());
	}

	function mint(
		address to,
		uint256 token0,
		uint256 token1,
		uint256 num,
		uint256 denom,
		uint256 expiry,
		uint256 settlement,
		address settler,
		uint256 amount
	) external {
		if (block.timestamp <= expiry || (block.timestamp <= settlement && msg.sender != settler))
			revert AccessDenied();

		bool swap;
		if (swap = token1 > token0) {
			(token0, token1) = (token1, token0);
			(num, denom) = (denom, num);
		}

		unchecked {
			blueprintManager.mint(
				to,
				uint256(keccak256(
					abi.encodePacked(token0, token1, num, denom, expiry, settlement, settler)
				)) + (swap ? 1 : 0),
				amount
			);
		}
	}
}
