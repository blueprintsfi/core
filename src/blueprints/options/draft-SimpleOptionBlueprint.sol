// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";

struct Config {
	uint256 token0;
	uint256 token1;
	uint256 num;
	uint256 denom;
	uint256 expiry;
	uint256 settlement;
	address settler;
	uint256 count;
}

contract SimpleOptionBlueprint is BasicBlueprint {
	constructor(IBlueprintManager manager) BasicBlueprint(manager) {}

	function executeAction(bytes calldata action) external onlyManager returns (
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		(Config memory config, bool mint) = abi.decode(action, (Config, bool));
		TokenOp[] memory giveTake = oneOperationArray(config.token0, config.num * config.count);

		(uint256 short, uint256 long) = getTokens(config);

		TokenOp[] memory mintBurn = new TokenOp[](2);
		mintBurn[0] = TokenOp(short, config.count);
		mintBurn[1] = TokenOp(long, config.count);

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

	function mint(address to, Config calldata config) external {
		if (block.timestamp <= config.expiry)
			revert AccessDenied();
		if (block.timestamp <= config.settlement && msg.sender != config.settler)
			revert AccessDenied();

		(,uint256 long) = getTokens(config);
		blueprintManager.mint(to, long, config.count);
	}

	function getTokens(Config memory config) internal pure returns (uint256 short, uint256 long) {
		bool swap = config.token0 < config.token1;
		if (swap) {
			(config.token0, config.token1) = (config.token1, config.token0);
			(config.num, config.denom) = (config.denom, config.num);
		}

		assembly ("memory-safe") {
			short := keccak256(config, 0xe0)
		}
		unchecked {
			long = short + (swap ? 1 : 2);
		}
	}
}
