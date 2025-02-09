// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import {HashLib} from "./libraries/HashLib.sol";
import {IBlueprint} from "./interfaces/IBlueprint.sol";
import {IBlueprintManager, TokenOp, BlueprintCall} from "./interfaces/IBlueprintManager.sol";
import {FlashAccounting, FlashSession, MainClue, FlashUserSession, UserClue} from "./FlashAccounting.sol";

contract BlueprintManager is IBlueprintManager, FlashAccounting {
    error InvalidChecksum();
    error AccessDenied();

    /// @notice eip-6909 operator mapping
    mapping(address => mapping(address => bool)) public isOperator;
    /// @notice eip-6909 balance mapping
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    /// @notice eip-6909 allowance mapping
    mapping(address => mapping(address => mapping(uint256 => uint256)))
        public allowance;

    function _mint(address to, uint256 id, uint256 amount) internal override {
        balanceOf[to][id] += amount;
    }

    function _burn(address from, uint256 id, uint256 amount) internal override {
        balanceOf[from][id] -= amount;
    }

    function _transferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount
    ) internal {
        _burn(from, id, amount);
        _mint(to, id, amount);
    }

    function _decreaseApproval(
        address sender,
        uint256 id,
        uint256 amount
    ) internal {
        uint256 allowed = allowance[sender][msg.sender][id];
        if (allowed != type(uint256).max) {
            allowance[sender][msg.sender][id] = allowed - amount;
        }
    }

    function transfer(
        address receiver,
        uint256 id,
        uint256 amount
    ) public virtual returns (bool) {
        _transferFrom(msg.sender, receiver, id, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount
    ) public virtual returns (bool) {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            _decreaseApproval(sender, id, amount);
        }

        _transferFrom(sender, receiver, id, amount);
        return true;
    }

    function approve(
        address spender,
        uint256 id,
        uint256 amount
    ) public virtual returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        return true;
    }

    function setOperator(
        address operator,
        bool approved
    ) public virtual returns (bool) {
        isOperator[msg.sender][operator] = approved;
        return true;
    }

    function cook(address realizer, BlueprintCall[] calldata calls) external {
        (FlashSession session, MainClue mainClue) = openFlashAccounting(
            realizer
        );

        uint256 len = calls.length;
        for (uint256 k = 0; k < len; k++) {
            _flashCook(calls[k], session);
        }

        closeFlashAccounting(mainClue, session);
    }

    function cook(BlueprintCall[] calldata calls) external {
        FlashSession session = getCurrentSession();

        uint256 len = calls.length;
        for (uint256 k = 0; k < len; k++) {
            _flashCook(calls[k], session);
        }
    }

    function _executeAction(
        BlueprintCall calldata call
    )
        internal
        returns (
            TokenOp[] memory tokensToMint,
            TokenOp[] memory tokensToBurn,
            TokenOp[] memory tokensToGive,
            TokenOp[] memory tokensToTake
        )
    {
        // optimistically ask for execution
        (tokensToMint, tokensToBurn, tokensToGive, tokensToTake) = IBlueprint(
            call.blueprint
        ).executeAction(call.action);

        if (call.checksum != 0) {
            // we read tokensToMint, tokensToBurn, tokensToGive, tokensToTake directly from returndata
            bytes32 expected = HashLib.hashActionResults();

            if (call.checksum != expected) revert InvalidChecksum();
        }
    }

    function _flashCook(
        BlueprintCall calldata call,
        FlashSession session
    ) internal {
        address blueprint = call.blueprint;

        bool checkApprovals;
        address sender = call.sender;
        if (sender == address(0)) {
            // no override
            sender = msg.sender;
        } else if (sender != msg.sender && !isOperator[sender][msg.sender]) {
            checkApprovals = true;
        }

        (
            TokenOp[] memory tokensToMint,
            TokenOp[] memory tokensToBurn,
            TokenOp[] memory tokensToGive,
            TokenOp[] memory tokensToTake
        ) = _executeAction(call);

        (
            FlashUserSession senderSession,
            UserClue senderClue
        ) = initializeUserSession(session, sender);

        for (uint256 i = 0; i < tokensToMint.length; i++) {
            senderClue = addUserCreditWithClue(
                senderSession,
                senderClue,
                HashLib.getTokenId(blueprint, tokensToMint[i].tokenId),
                tokensToMint[i].amount
            );
        }

        for (uint256 i = 0; i < tokensToBurn.length; i++) {
            uint256 tokenId = HashLib.getTokenId(
                blueprint,
                tokensToBurn[i].tokenId
            );
            uint256 amount = tokensToBurn[i].amount;

            if (checkApprovals) _decreaseApproval(sender, tokenId, amount);

            senderClue = addUserDebitWithClue(
                senderSession,
                senderClue,
                tokenId,
                amount
            );
        }

        if (
            blueprint != sender &&
            (tokensToGive.length != 0 || tokensToTake.length != 0)
        ) {
            (
                FlashUserSession blueprintSession,
                UserClue blueprintClue
            ) = initializeUserSession(session, blueprint);

            for (uint256 i = 0; i < tokensToGive.length; i++) {
                uint256 id = tokensToGive[i].tokenId;
                uint256 amount = tokensToGive[i].amount;
                senderClue = addUserCreditWithClue(
                    senderSession,
                    senderClue,
                    id,
                    amount
                );
                blueprintClue = addUserDebitWithClue(
                    blueprintSession,
                    blueprintClue,
                    id,
                    amount
                );
            }

            for (uint256 i = 0; i < tokensToTake.length; i++) {
                uint256 id = tokensToTake[i].tokenId;
                uint256 amount = tokensToTake[i].amount;

                if (checkApprovals) _decreaseApproval(sender, id, amount);

                senderClue = addUserDebitWithClue(
                    senderSession,
                    senderClue,
                    id,
                    amount
                );
                blueprintClue = addUserCreditWithClue(
                    blueprintSession,
                    blueprintClue,
                    id,
                    amount
                );
            }
            saveUserClue(blueprintSession, blueprintClue);
        }
        saveUserClue(senderSession, senderClue);
    }

    function credit(uint256 id, uint256 amount) external {
        FlashSession session = getCurrentSession();

        (
            FlashUserSession userSession,
            UserClue userClue
        ) = initializeUserSession(session, msg.sender);

        UserClue newUserClue = addUserDebitWithClue(
            userSession,
            userClue,
            id,
            amount
        );
        if (UserClue.unwrap(userClue) != UserClue.unwrap(newUserClue)) {
            saveUserClue(userSession, newUserClue);
        }
        _mint(msg.sender, id, amount);
    }

    function credit(TokenOp[] calldata ops) external {
        FlashSession session = getCurrentSession();

        (
            FlashUserSession userSession,
            UserClue userClue
        ) = initializeUserSession(session, msg.sender);

        uint256 len = ops.length;
        for (uint256 i = 0; i < len; i++) {
            TokenOp calldata op = ops[i];
            uint256 id = op.tokenId;
            uint256 amount = op.amount;
            userClue = addUserDebitWithClue(userSession, userClue, id, amount);
            _mint(msg.sender, id, amount);
        }
        saveUserClue(userSession, userClue);
    }

    function debit(uint256 id, uint256 amount) external {
        FlashSession session = getCurrentSession();

        (
            FlashUserSession userSession,
            UserClue userClue
        ) = initializeUserSession(session, msg.sender);

        UserClue newUserClue = addUserCreditWithClue(
            userSession,
            userClue,
            id,
            amount
        );
        if (UserClue.unwrap(userClue) != UserClue.unwrap(newUserClue)) {
            saveUserClue(userSession, newUserClue);
        }
        _burn(msg.sender, id, amount);
    }

    function debit(TokenOp[] calldata ops) external {
        FlashSession session = getCurrentSession();

        (
            FlashUserSession userSession,
            UserClue userClue
        ) = initializeUserSession(session, msg.sender);

        uint256 len = ops.length;
        for (uint256 i = 0; i < len; i++) {
            TokenOp calldata op = ops[i];
            uint256 id = op.tokenId;
            uint256 amount = op.amount;
            userClue = addUserCreditWithClue(userSession, userClue, id, amount);
            _burn(msg.sender, id, amount);
        }
        saveUserClue(userSession, userClue);
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, HashLib.getTokenId(msg.sender, tokenId), amount);
    }

    function mint(address to, TokenOp[] calldata ops) external {
        uint256 len = ops.length;

        for (uint256 i = 0; i < len; i++) {
            _mint(
                to,
                HashLib.getTokenId(msg.sender, ops[i].tokenId),
                ops[i].amount
            );
        }
    }

    function burn(uint256 tokenId, uint256 amount) external {
        _burn(msg.sender, HashLib.getTokenId(msg.sender, tokenId), amount);
    }

    function burn(TokenOp[] calldata ops) external {
        uint256 len = ops.length;

        for (uint256 i = 0; i < len; i++) {
            _burn(
                msg.sender,
                HashLib.getTokenId(msg.sender, ops[i].tokenId),
                ops[i].amount
            );
        }
    }
}
