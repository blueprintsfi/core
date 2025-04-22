// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";
import {gcd} from "../../libraries/Math.sol";

contract SimpleOptionBlueprint is BasicBlueprint {
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

		(uint256 short, uint256 long, uint256 amount) =
			getTokens(token0, token1, num, denom, expiry, settlement, settler);

		TokenOp[] memory mintBurn = new TokenOp[](2);
		mintBurn[0] = TokenOp(short, amount);
		mintBurn[1] = TokenOp(long, amount);

		// send tokens to respective subaccount for reserve isolation
		blueprintManager.flashTransferFrom(
			address(this),
			mint ? 0 : long,
			address(this),
			mint ? long : 0,
			giveTake
		);

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
		address settler
	) external {
		if (block.timestamp <= expiry || (block.timestamp <= settlement && msg.sender != settler))
			revert AccessDenied();

		(,uint256 long, uint256 amount) =
			getTokens(token0, token1, num, denom, expiry, settlement, settler);

		blueprintManager.mint(to, long, amount);
	}

	function getTokens(
		uint256 token0,
		uint256 token1,
		uint256 num,
		uint256 denom,
		uint256 expiry,
		uint256 settlement,
		address settler
	) internal pure returns (uint256 short, uint256 long, uint256 amount) {
		amount = gcd(num, denom);
		(num, denom) = (num / amount, denom / amount);

		bool swap = token0 < token1;
		if (swap) {
			(token0, token1) = (token1, token0);
			(num, denom) = (denom, num);
		}

		uint256 id = uint256(keccak256(
			abi.encodePacked(token0, token1, num, denom, expiry, settlement, settler)
		));

		unchecked {
			short = id + 2;
			long = id + (swap ? 1 : 0);
		}
	}
}
