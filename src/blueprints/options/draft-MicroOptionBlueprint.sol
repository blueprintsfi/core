// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";
import {gcd} from "../../libraries/Math.sol";

// an overly simplified option blueprint which leaks value to arbitrageurs at expiry
contract MicroOptionBlueprint is BasicBlueprint {
	mapping (uint256 baseId => uint256 count) public reserves;

	constructor(IBlueprintManager manager) BasicBlueprint(manager) {}

	function executeAction(bytes calldata action) external onlyManager returns (
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		(uint256 token0, uint256 token1, uint256 num, uint256 denom, uint256 expiry, bool mint) =
			abi.decode(action, (uint256, uint256, uint256, uint256, uint256, bool));

		TokenOp[] memory giveTake = oneOperationArray(token0, num);

		uint256 amount = gcd(num, denom);
		(num, denom) = (num / amount, denom / amount);

		bool swap = token1 < token0;
		if (swap) {
			(token0, token1) = (token1, token0);
			(num, denom) = (denom, num);
		}

		uint256 short;
		uint256 long;
		unchecked {
			short = uint256(keccak256(abi.encodePacked(token0, token1, num, denom, expiry))) + 2;
			long = short - (swap ? 1 : 2);
		}

		TokenOp[] memory mintBurn = new TokenOp[](2);
		mintBurn[0] = TokenOp(short, amount);
		if (block.timestamp < expiry || mint)
			mintBurn[1] = TokenOp(long, amount);

		if (mint)
			reserves[long] += amount;
		else // underflow check prevents from going beyond reserves
			reserves[long] -= amount;

		return mint ?
			(mintBurn, zero(), zero(), giveTake) :
			(zero(), mintBurn, giveTake, zero());
	}
}
