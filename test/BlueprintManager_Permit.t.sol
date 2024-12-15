// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {BlueprintManager} from "../src/BlueprintManager.sol";

import {console} from "forge-std/console.sol";

contract BlueprintManagerTest is Test {

	BlueprintManager manager = new BlueprintManager();
    address owner;
    address spender;
    address operator;
    address invalidSigner;
    uint256 ownerKey;
    uint256 spenderKey;
    uint256 operatorKey;
    uint256 invalidSignerKey;
    uint256 tokenId = 1;
    uint256 amount = 100;
    uint256 deadline;
    bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 public constant OPERATOR_PERMIT_TYPEHASH = keccak256("PermitOperator(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)");

	function setUp() external {
		vm.deal(address(this), type(uint).max);

        // Setup test accounts
        (owner, ownerKey) = makeAddrAndKey("owner");
        (spender, spenderKey) = makeAddrAndKey("spender");
        (operator, operatorKey) = makeAddrAndKey("operator");
        (invalidSigner, invalidSignerKey) = makeAddrAndKey("invalidSigner");

        // Deploy BlueprintManager contract
        deadline = block.timestamp + 1 hours;    
	}

    function testPermit() public {
        // Sign the permit
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                owner,
                spender,
                tokenId,
                amount,
                0, // nonce
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", manager.DOMAIN_SEPARATOR(), structHash));
        console.logBytes32(bytes32(bytes20(uint160(owner))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        // Perform the permit
        vm.prank(owner);
        manager.permit(owner, spender, tokenId, amount, deadline, v, r, s);

        // Verify that allowance was set correctly
        (uint256 allowedAmount) = manager.allowance(owner, spender, tokenId);
        assertEq(allowedAmount, amount);
    }

    function testPermitInvalidSignature() public {
        // Sign the permit with the wrong signer
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                owner,
                spender,
                tokenId,
                amount,
                0, // nonce
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", manager.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(invalidSignerKey, digest);

        // Try to execute the permit with an invalid signature (should fail)
        vm.expectRevert(abi.encodeWithSelector(BlueprintManager.InvalidSignature.selector));
        vm.prank(owner);
        manager.permit(owner, spender, tokenId, amount, deadline, v, r, s);
    }

    function testPermitExpired() public {
        // Sign the permit
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                owner,
                spender,
                tokenId,
                amount,
                0, // nonce
                block.timestamp - 1 // expired deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", manager.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        // Try to execute the permit after expiration (should fail)
        vm.expectRevert("Permit expired");
        vm.prank(owner);
        manager.permit(owner, spender, tokenId, amount, block.timestamp - 1, v, r, s);
    }

    function testPermitOperator() public {
        // Sign the operator permit
        bytes32 structHash = keccak256(
            abi.encode(
                OPERATOR_PERMIT_TYPEHASH,
                owner,
                operator,
                true,
                0, // nonce
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", manager.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        // Perform the permitOperator
        vm.prank(owner);
        manager.permitOperator(owner, operator, true, deadline, v, r, s);

        // Check if operator is approved
        bool isApproved = manager.isOperator(owner, operator);
        assertTrue(isApproved);
    }

    function testPermitOperatorRevoke() public {
        // Sign the operator permit to revoke
        bytes32 structHash = keccak256(
            abi.encode(
                OPERATOR_PERMIT_TYPEHASH,
                owner,
                operator,
                false,
                0, // nonce
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", manager.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        // Revoke operator approval
        vm.prank(owner);
        manager.permitOperator(owner, operator, false, deadline, v, r, s);

        // Check if operator is not approved
        bool isApproved = manager.isOperator(owner, operator);
        assertFalse(isApproved);
    }

    // Helper function to sign data
    function sign(bytes32 digest, address signer) internal returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
