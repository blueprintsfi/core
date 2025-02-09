// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {FlashAccounting} from "../src/FlashAccounting.sol";
import {UserClue, FlashSession, FlashUserSession, MainClue, SessionClue} from "../src/FlashAccounting.sol";

contract MockToken is FlashAccounting {
    mapping(address => mapping(uint256 => uint256)) public balances;

    function _mint(address to, uint256 id, uint256 amount) internal override {
        balances[to][id] += amount;
    }

    function _burn(address from, uint256 id, uint256 amount) internal override {
        require(balances[from][id] >= amount, "Insufficient balance");
        balances[from][id] -= amount;
    }

    function balanceOf(address user, uint256 id) public view returns (uint256) {
        return balances[user][id];
    }

    // Wrapper functions to expose internal functions for testing
    function openFlashAccountingTest(
        address realizer
    ) external returns (FlashSession session, MainClue mainClue) {
        return openFlashAccounting(realizer);
    }

    function closeFlashAccountingTest(
        MainClue mainClue,
        FlashSession session
    ) external {
        closeFlashAccounting(mainClue, session);
    }

    function initializeUserSessionTest(
        FlashSession session,
        address user
    ) external returns (FlashUserSession userSession, UserClue userClue) {
        return initializeUserSession(session, user);
    }

    function addUserCreditWithClueTest(
        FlashUserSession userSession,
        UserClue userClue,
        uint256 id,
        uint256 amount
    ) external returns (UserClue) {
        return addUserCreditWithClue(userSession, userClue, id, amount);
    }

    function addUserDebitWithClueTest(
        FlashUserSession userSession,
        UserClue userClue,
        uint256 id,
        uint256 amount
    ) external returns (UserClue) {
        return addUserDebitWithClue(userSession, userClue, id, amount);
    }

    function saveUserClueTest(
        FlashUserSession userSession,
        UserClue userClue
    ) external {
        saveUserClue(userSession, userClue);
    }

    function getCurrentSessionTest() external view returns (FlashSession) {
        return getCurrentSession();
    }
}

contract FlashAccountingTest is Test {
    MockToken public token;
    address public user1;
    address public user2;

    function setUp() public {
        token = new MockToken();
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
    }

    function testBasicFlashMinting() public {
        // Open flash accounting session
        (FlashSession session, MainClue mainClue) = token
            .openFlashAccountingTest(address(0));

        // Initialize user session
        (FlashUserSession userSession, UserClue userClue) = token
            .initializeUserSessionTest(session, user1);

        uint256 id = 1;
        uint256 amount = 100;
        UserClue newUserClue = token.addUserCreditWithClueTest(
            userSession,
            userClue,
            id,
            amount
        );

        // Save the user clue
        token.saveUserClueTest(userSession, newUserClue);

        // Close flash accounting
        token.closeFlashAccountingTest(mainClue, session);

        // Check final balance
        assertEq(token.balanceOf(user1, id), amount);
    }

    function testBasicFlashBurning() public {
        // First mint some tokens normally
        (FlashSession session1, MainClue mainClue1) = token
            .openFlashAccountingTest(address(0));
        (FlashUserSession userSession1, UserClue userClue1) = token
            .initializeUserSessionTest(session1, user1);
        UserClue newUserClue1 = token.addUserCreditWithClueTest(
            userSession1,
            userClue1,
            1,
            200
        );
        token.saveUserClueTest(userSession1, newUserClue1);
        token.closeFlashAccountingTest(mainClue1, session1);

        // Now test burning
        (FlashSession session2, MainClue mainClue2) = token
            .openFlashAccountingTest(address(0));
        (FlashUserSession userSession2, UserClue userClue2) = token
            .initializeUserSessionTest(session2, user1);
        UserClue newUserClue2 = token.addUserDebitWithClueTest(
            userSession2,
            userClue2,
            1,
            100
        );
        token.saveUserClueTest(userSession2, newUserClue2);
        token.closeFlashAccountingTest(mainClue2, session2);

        assertEq(token.balanceOf(user1, 1), 100);
    }

    function testMultipleUsersInSession() public {
        (FlashSession session, MainClue mainClue) = token
            .openFlashAccountingTest(address(0));

        // User 1 operations
        (FlashUserSession userSession1, UserClue userClue1) = token
            .initializeUserSessionTest(session, user1);
        UserClue newUserClue1 = token.addUserCreditWithClueTest(
            userSession1,
            userClue1,
            1,
            100
        );
        token.saveUserClueTest(userSession1, newUserClue1);

        // User 2 operations
        (FlashUserSession userSession2, UserClue userClue2) = token
            .initializeUserSessionTest(session, user2);
        UserClue newUserClue2 = token.addUserCreditWithClueTest(
            userSession2,
            userClue2,
            1,
            200
        );
        token.saveUserClueTest(userSession2, newUserClue2);

        token.closeFlashAccountingTest(mainClue, session);

        assertEq(token.balanceOf(user1, 1), 100);
        assertEq(token.balanceOf(user2, 1), 200);
    }

    function testMultipleTokensPerUser() public {
        (FlashSession session, MainClue mainClue) = token
            .openFlashAccountingTest(address(0));
        (FlashUserSession userSession, UserClue userClue) = token
            .initializeUserSessionTest(session, user1);

        // Add multiple tokens
        UserClue newUserClue = userClue;
        newUserClue = token.addUserCreditWithClueTest(
            userSession,
            newUserClue,
            1,
            100
        );
        newUserClue = token.addUserCreditWithClueTest(
            userSession,
            newUserClue,
            2,
            200
        );
        newUserClue = token.addUserCreditWithClueTest(
            userSession,
            newUserClue,
            3,
            300
        );

        token.saveUserClueTest(userSession, newUserClue);
        token.closeFlashAccountingTest(mainClue, session);

        assertEq(token.balanceOf(user1, 1), 100);
        assertEq(token.balanceOf(user1, 2), 200);
        assertEq(token.balanceOf(user1, 3), 300);
    }

    function testRealizerRestriction() public {
        address realizer = makeAddr("realizer");

        // Open session with realizer
        vm.startPrank(realizer);
        (FlashSession session, MainClue mainClue) = token
            .openFlashAccountingTest(realizer);

        uint256 storedClue = uint256(MainClue.unwrap(mainClue));

        console.log("Stored mainClue:", storedClue);
        uint256 expectedRealizerBits = uint256(uint160(realizer)); // Changed this line
        console.log("Expected realizer:", expectedRealizerBits);
        console.log("Actual realizer:", storedClue >> 96);
        vm.stopPrank();

        // Try to close from wrong address
        vm.prank(address(1));
        vm.expectRevert(FlashAccounting.RealizeAccessDenied.selector);
        token.closeFlashAccountingTest(mainClue, session);

        // Should succeed with correct realizer
        vm.prank(realizer);
        token.closeFlashAccountingTest(mainClue, session);
    }

    function testNoActiveSession() public {
        vm.expectRevert(FlashAccounting.NoFlashAccountingActive.selector);
        token.getCurrentSessionTest();
    }

    function testLargeNumbers() public {
        (FlashSession session, MainClue mainClue) = token
            .openFlashAccountingTest(address(0));
        (FlashUserSession userSession, UserClue userClue) = token
            .initializeUserSessionTest(session, user1);

        // Test with numbers close to type(uint256).max
        uint256 largeAmount = type(uint256).max - 1000;
        UserClue newUserClue = token.addUserCreditWithClueTest(
            userSession,
            userClue,
            1,
            largeAmount
        );
        token.saveUserClueTest(userSession, newUserClue);
        token.closeFlashAccountingTest(mainClue, session);

        assertEq(token.balanceOf(user1, 1), largeAmount);
    }

    function testBalanceOverflow() public {
        (FlashSession session, MainClue mainClue) = token
            .openFlashAccountingTest(address(0));
        (FlashUserSession userSession, UserClue userClue) = token
            .initializeUserSessionTest(session, user1);

        // First add close to int256.max to set extension bit
        uint256 amount1 = uint256(type(int256).max) - 1;
        UserClue newUserClue = token.addUserCreditWithClueTest(
            userSession,
            userClue,
            1,
            amount1
        );

        // Add enough to push the total over int256.max multiple times
        // This should cause the extension value to exceed 2
        for (uint256 i = 0; i < 3; i++) {
            newUserClue = token.addUserCreditWithClueTest(
                userSession,
                newUserClue,
                1,
                type(uint256).max / 4
            );

            // Print intermediate values
            bytes32 deltaSlot;
            assembly {
                mstore(0, 1) // token id
                mstore(0x20, userSession)
                deltaSlot := keccak256(0, 0x40)
            }
            uint256 deltaValue = token.exttload(uint256(deltaSlot));
            uint256 extensionValue = token.exttload(uint256(deltaSlot) + 1);
            console.log("After addition", i + 1);
            console.log("Delta value:", deltaValue);
            console.log("Extension value:", extensionValue);
        }

        token.saveUserClueTest(userSession, newUserClue);

        vm.expectRevert(FlashAccounting.BalanceDeltaOverflow.selector);
        token.closeFlashAccountingTest(mainClue, session);
    }

    function testDeltaValues() public {
        (FlashSession session, MainClue mainClue) = token
            .openFlashAccountingTest(address(0));
        (FlashUserSession userSession, UserClue userClue) = token
            .initializeUserSessionTest(session, user1);

        // Add a value that should be close to max
        uint256 amount = (1 << 255) - 2;
        UserClue newUserClue = token.addUserCreditWithClueTest(
            userSession,
            userClue,
            1,
            amount
        );
        token.saveUserClueTest(userSession, newUserClue);

        // Get the delta value through exttload (assuming you have this helper function)
        bytes32 deltaSlot;
        assembly {
            mstore(0, 1) // token id
            mstore(0x20, userSession)
            deltaSlot := keccak256(0, 0x40)
        }
        uint256 deltaValue = token.exttload(uint256(deltaSlot));
        console.log("Delta value:", deltaValue);

        // Try to close and see what happens
        token.closeFlashAccountingTest(mainClue, session);
    }

    function testStorageLayout() public {
        (FlashSession session, ) = token.openFlashAccountingTest(address(0));
        (FlashUserSession userSession, UserClue userClue) = token
            .initializeUserSessionTest(session, user1);

        uint256 amount = 1 << 254;
        UserClue newUserClue = token.addUserCreditWithClueTest(
            userSession,
            userClue,
            1,
            amount
        );
        token.saveUserClueTest(userSession, newUserClue);

        // Get storage value for the delta slot
        bytes32 deltaSlot;
        assembly {
            mstore(0, 1) // token id
            mstore(0x20, userSession)
            deltaSlot := keccak256(0, 0x40)
        }
        uint256 deltaValue = token.exttload(uint256(deltaSlot));
        console.log("Delta value:", deltaValue);
        uint256 extensionValue = token.exttload(uint256(deltaSlot) + 1);
        console.log("Extension value:", extensionValue);
    }
}
