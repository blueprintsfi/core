// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";
import {gcd} from "../../libraries/Math.sol";
import {IVestingSchedule} from "./schedules/IVestingSchedule.sol";

contract VestingBlueprint is BasicBlueprint {
    error UnalignedBatchSize();

    struct ActionParams {
        uint256 tokenId;
        uint256 amount;
        uint256 filled;
        address vestingSchedule;
        bytes scheduleArgs;
        uint256 preferredFinalBatch;
        uint256 desiredFillPerBatch;
    }

    struct BatchParams {
        uint256 batchSize;
        uint256 fillPerBatch;
        uint256 amount;
        bytes vestingStruct;
    }

    constructor(IBlueprintManager _blueprintManager) BasicBlueprint(_blueprintManager) {}

    function executeAction(bytes calldata action)
        external
        view
        returns (
            TokenOp[] memory tokensToMint,
            TokenOp[] memory tokensToBurn,
            TokenOp[] memory tokensToGive,
            TokenOp[] memory tokensToTake
        )
    {
        ActionParams memory params = abi.decode(action, (ActionParams));

        if (params.amount == 0) {
            return (zero(), zero(), zero(), zero());
        }

        if (params.amount % params.preferredFinalBatch != 0) {
            revert UnalignedBatchSize();
        }

        uint256 finalFilled = (params.amount / params.preferredFinalBatch) * params.desiredFillPerBatch;
        bool addTokens = finalFilled >= params.filled;

        uint256 initBatchDenom = gcd(params.amount, params.filled);
        bytes memory vestingStruct = getVestingStruct(params.tokenId, params.vestingSchedule, params.scheduleArgs);

        BatchParams memory burnParams = BatchParams({
            batchSize: params.amount / initBatchDenom,
            fillPerBatch: params.filled / initBatchDenom,
            amount: initBatchDenom,
            vestingStruct: vestingStruct
        });

        tokensToBurn =
            getOperation(burnParams.vestingStruct, burnParams.batchSize, burnParams.fillPerBatch, burnParams.amount);

        if (!addTokens) {
            uint256 maxFinalBatch = params.preferredFinalBatch
                - IVestingSchedule(params.vestingSchedule).getVestedTokens(params.preferredFinalBatch, params.scheduleArgs);

            if (maxFinalBatch > params.desiredFillPerBatch) {
                params.desiredFillPerBatch = maxFinalBatch;
                finalFilled = (params.amount / params.preferredFinalBatch) * params.desiredFillPerBatch;
                if (finalFilled >= params.filled) {
                    return (zero(), zero(), zero(), zero());
                }
            }
        }

        uint256 finalBatchDenom = gcd(params.desiredFillPerBatch, params.preferredFinalBatch);

        BatchParams memory mintParams = BatchParams({
            batchSize: params.preferredFinalBatch / finalBatchDenom,
            fillPerBatch: params.desiredFillPerBatch / finalBatchDenom,
            amount: params.amount / (params.preferredFinalBatch / finalBatchDenom),
            vestingStruct: vestingStruct
        });

        tokensToMint =
            getOperation(mintParams.vestingStruct, mintParams.batchSize, mintParams.fillPerBatch, mintParams.amount);

        if (addTokens) {
            tokensToGive = zero();
            tokensToTake = oneOperationArray(params.tokenId, finalFilled - params.filled);
        } else {
            tokensToGive = oneOperationArray(params.tokenId, params.filled - finalFilled);
            tokensToTake = zero();
        }
    }

    function getVestingStruct(uint256 tokenId, address vestingSchedule, bytes memory scheduleArgs)
        internal
        pure
        returns (bytes memory res)
    {
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

    function setVestingParams(bytes memory vestingStruct, uint256 amount, uint256 filled) internal pure {
        assembly ("memory-safe") {
            mstore(add(vestingStruct, 0x40), amount)
            mstore(add(vestingStruct, 0x60), filled)
        }
    }

    function getOperation(bytes memory vestingStruct, uint256 batchSize, uint256 fillPerBatch, uint256 amount)
        internal
        pure
        returns (TokenOp[] memory)
    {
        if (fillPerBatch != 0) {
            setVestingParams(vestingStruct, batchSize, fillPerBatch);
            return oneOperationArray(uint256(keccak256(vestingStruct)), amount);
        } else {
            return zero();
        }
    }
}
