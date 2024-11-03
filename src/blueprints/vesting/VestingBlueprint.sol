// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";
import {gcd} from "../../libraries/Math.sol";
import {IVestingSchedule} from "./schedules/IVestingSchedule.sol";

contract VestingBlueprint is BasicBlueprint {
	error UnalignedBatchSize();

	constructor(IBlueprintManager _blueprintManager)
		BasicBlueprint(_blueprintManager) {}

	// the onlyManager modifier is removed because it's a pure/view function
	function executeAction(
		bytes calldata action
	) external view returns (
		TokenOp[] memory /*mint*/,
		TokenOp[] memory /*burn*/,
		TokenOp[] memory /*give*/,
		TokenOp[] memory /*take*/
	) {
		(
			uint256 tokenId,
			uint256 amount,
			uint256 filled,
			address vestingSchedule,
			bytes memory scheduleArgs,
			uint256 preferredFinalBatch,
			uint256 desiredFillPerBatch
		) = abi.decode(
			action,
			(uint256, uint256, uint256, address, bytes, uint256, uint256)
		);

		if (amount == 0)
			return (zero(), zero(), zero(), zero());

		if (amount % preferredFinalBatch != 0)
			revert UnalignedBatchSize();

		uint256 finalFilled = amount / preferredFinalBatch * desiredFillPerBatch;
		bool addTokens = finalFilled >= filled;

		uint256 initBatchDenom = gcd(amount, filled);
		// there is only one dynamic array, so using encodePacked() is safe
		bytes memory vestingStruct = getVestingStruct(
			tokenId,
			vestingSchedule,
			scheduleArgs
		);

		TokenOp[] memory burn = getOperation(
			vestingStruct,
			amount / initBatchDenom,
			filled / initBatchDenom,
			initBatchDenom
		);

		if (!addTokens) {
			// subtraction overflow check prevents vesting schedule misbehavior,
			// its result exceeding argument will simply cause the action
			// execution to revert
			uint256 maxFinalBatch = preferredFinalBatch -
				IVestingSchedule(vestingSchedule).getVestedTokens(
					preferredFinalBatch,
					scheduleArgs
				);
			if (maxFinalBatch > desiredFillPerBatch) {
				desiredFillPerBatch = maxFinalBatch;
				finalFilled = amount / preferredFinalBatch * desiredFillPerBatch;
				// we're supposed to be removing tokens, verify it's still the
				// case, else execute a null action
				if (finalFilled >= filled)
					return (zero(), zero(), zero(), zero());
			}
		}

		uint256 finalBatchDenom = gcd(desiredFillPerBatch, preferredFinalBatch);
		uint256 finalBatchSize = preferredFinalBatch / finalBatchDenom;
		TokenOp[] memory mint = getOperation(
			vestingStruct,
			finalBatchSize,
			desiredFillPerBatch / finalBatchDenom,
			amount / finalBatchSize
		);

		(TokenOp[] memory give, TokenOp[] memory take) = addTokens ?
			(zero(), oneOperationArray(tokenId, finalFilled - filled)) :
			(oneOperationArray(tokenId, filled - finalFilled), zero());

		return (mint, burn, give, take);
	}

	function getVestingStruct(
		uint256 tokenId,
		address vestingSchedule,
		bytes memory scheduleArgs
	) internal pure returns (bytes memory res) {
		assembly ("memory-safe") {
			res := mload(0x40)
			mstore(add(res, 0x20), tokenId)
			mstore(add(res, 0x74), vestingSchedule)

			let size := mload(scheduleArgs)
			mcopy(add(res, 0x94), add(scheduleArgs, 0x20), size)
			mstore(res, add(size, 0x74))
			mstore(0x40, add(res, add(size, 0x94)))
		}
	}

	function setVestingParams(
		bytes memory vestingStruct,
		uint256 amount,
		uint256 filled
	) internal pure {
		assembly ("memory-safe") {
			mstore(add(vestingStruct, 0x40), amount)
			mstore(add(vestingStruct, 0x60), filled)
		}
	}

	function getOperation(
		bytes memory vestingStruct,
		uint256 batchSize,
		uint256 fillPerBatch,
		uint256 amount
	) internal pure returns (TokenOp[] memory) {
		if (fillPerBatch != 0) {
			setVestingParams(
				vestingStruct,
				batchSize,
				fillPerBatch
			);
			return oneOperationArray(
				uint256(keccak256(vestingStruct)),
				amount
			);
		} else {
			return zero();
		}
	}
}
