// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicBlueprint, TokenOp, IBlueprintManager} from "../BasicBlueprint.sol";
import {gcd} from "../../libraries/Math.sol";

contract SimpleOptionBlueprint is BasicBlueprint {
    mapping(uint256 baseId => uint256 count) public reserves;

    constructor(IBlueprintManager manager) BasicBlueprint(manager) {}

    struct ActionParams {
        uint256 token0;
        uint256 token1;
        uint256 num;
        uint256 denom;
        uint256 expiry;
        uint256 settlement;
        address settler;
        bool isCreating;
    }

    struct TokenIds {
        uint256 short;
        uint256 long;
        uint256 amount;
    }

    function executeAction(bytes calldata action)
        external
        onlyManager
        returns (
            TokenOp[] memory tokensToMint,
            TokenOp[] memory tokensToBurn,
            TokenOp[] memory tokensToGive,
            TokenOp[] memory tokensToTake
        )
    {
        ActionParams memory params = abi.decode(action, (ActionParams));

        tokensToGive = params.isCreating ? oneOperationArray(params.token0, params.num) : zero();
        tokensToTake = params.isCreating ? zero() : oneOperationArray(params.token0, params.num);

        TokenIds memory ids = getTokens(
            params.token0, params.token1, params.num, params.denom, params.expiry, params.settlement, params.settler
        );

        TokenOp[] memory ops = new TokenOp[](2);
        ops[0] = TokenOp(ids.short, ids.amount);
        ops[1] = TokenOp(ids.long, ids.amount);

        if (params.isCreating) {
            reserves[ids.long] += ids.amount;
            tokensToMint = ops;
            tokensToBurn = zero();
        } else {
            reserves[ids.long] -= ids.amount;
            tokensToMint = zero();
            tokensToBurn = ops;
        }
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
        if (block.timestamp <= expiry || (block.timestamp <= settlement && msg.sender != settler)) {
            revert AccessDenied();
        }

        TokenIds memory ids = getTokens(token0, token1, num, denom, expiry, settlement, settler);
        blueprintManager.mint(to, ids.long, ids.amount);
    }

    function getTokens(
        uint256 token0,
        uint256 token1,
        uint256 num,
        uint256 denom,
        uint256 expiry,
        uint256 settlement,
        address settler
    ) internal pure returns (TokenIds memory ids) {
        ids.amount = gcd(num, denom);
        (num, denom) = (num / ids.amount, denom / ids.amount);

        bool swap = token0 < token1;
        if (swap) {
            (token0, token1) = (token1, token0);
            (num, denom) = (denom, num);
        }

        uint256 id = uint256(keccak256(abi.encodePacked(token0, token1, num, denom, expiry, settlement, settler)));

        unchecked {
            ids.short = id + 2;
            ids.long = id + (swap ? 1 : 0);
        }
    }
}
