// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IVestingSchedule} from "./IVestingSchedule.sol";

contract LinearCliffVestingSchedule is IVestingSchedule {
	function getVestedTokens(
		uint256 amount,
		bytes calldata scheduleArgs
	) external view returns (uint256 unlocked) {
		(uint256 startVesting, uint256 endVesting, uint256 cliff) =
			abi.decode(scheduleArgs, (uint256, uint256, uint256));

		if (startVesting > endVesting || cliff > endVesting) {
			// reverts have more severe consequences than wrongly encoding
			// parameters, so don't revert
			// revert InvalidArguments()

			// just simply consider the position fully unlocked
			return amount;
		}

		if (block.timestamp < cliff)
			return 0;

		if (block.timestamp > endVesting)
			return amount;

		unchecked {
			if (block.timestamp > startVesting)
				return amount * (block.timestamp - startVesting) / (endVesting - startVesting);
		}

		// if (block.timestamp <= startVesting)
		return 0;
	}
}
