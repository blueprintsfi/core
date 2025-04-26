// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {BlueprintManager, TokenOp, BlueprintCall, HashLib} from "../src/BlueprintManager.sol";
import {NativeBlueprint} from "../src/blueprints/wrappers/NativeBlueprint.sol";
import {ERC20Blueprint, IPermit2} from "../src/blueprints/wrappers/ERC20Blueprint.sol";
// import {VestingBlueprint, ISchedule} from "../src/blueprints/vesting/VestingBlueprint.sol";
import {BasketBlueprint} from "../src/blueprints/BasketBlueprint.sol";
import {ERC20 as ERC20Abstract} from "solmate/tokens/ERC20.sol";

import {LinearCliffVestingSchedule} from "../src/blueprints/vesting/schedules/LinearCliffVestingSchedule.sol";

import {BasicBlueprint, IBlueprintManager, IBlueprint} from "../src/blueprints/BasicBlueprint.sol";
import {gcd} from "../src/libraries/Math.sol";

contract ERC20 is ERC20Abstract("Test Token", "TT", 18) {
	function mint(address to, uint256 amount) public {
		_mint(to, amount);
	}
}

contract BlueprintManagerTest is Test {
	error NoFlashAccountingActive();

	BlueprintManager manager = new BlueprintManager();
	NativeBlueprint native = new NativeBlueprint(manager);
	// IBlueprint vesting = new VestingBlueprint(manager);
	ERC20Blueprint erc20wrapper = new ERC20Blueprint(manager, IPermit2(address(0)));
	IBlueprint basket = new BasketBlueprint(manager);
	// IVestingSchedule schedule = new LinearCliffVestingSchedule();
	ERC20 erc20 = new ERC20();

	BlueprintCall[] public scheduledCalls;

	bytes32 constant NULL_HASH = keccak256("");

	function setUp() external {
		vm.deal(address(this), type(uint).max);
	}

	function test_wrapNative(address to, uint256 amount) public returns (uint256 id) {
		id = HashLib.hash(address(native), 0);
		uint256 balance = manager.balanceOf(to, id);

		vm.assume(amount < address(this).balance);
		native.mint{value: amount}(to);

		assertEq(balance + amount, manager.balanceOf(to, id));
	}

	function test_transfer(address from, address to, uint256 amount) public {
		uint256 id = test_wrapNative(from, amount);
		uint256 balanceFrom = manager.balanceOf(from, id);
		uint256 balanceTo = manager.balanceOf(to, id);

		vm.prank(from);
		manager.transfer(to, id, amount);

		if (from != to) {
			assertEq(balanceFrom, manager.balanceOf(from, id) + amount);
			assertEq(balanceTo + amount, manager.balanceOf(to, id));
		} else {
			assertEq(balanceFrom, manager.balanceOf(from, id));
		}
	}

	function test_creditDebitRevertWithoutCool(address user, uint256 amount) external {
		uint256 id = test_wrapNative(user, amount);

		TokenOp[] memory ops = new TokenOp[](1);
		ops[0] = TokenOp(id, amount);

		vm.startPrank(user);

		vm.expectRevert(NoFlashAccountingActive.selector);
		manager.credit(id, amount);

		vm.expectRevert(NoFlashAccountingActive.selector);
		manager.credit(ops);

		vm.expectRevert(NoFlashAccountingActive.selector);
		manager.debit(id, amount);

		vm.expectRevert(NoFlashAccountingActive.selector);
		manager.debit(ops);

		vm.stopPrank();
	}

	function test_redeemNative(address from, uint256 amount, bool postChecksum) public {
		test_wrapNative(from, amount);
		address to = address(0xdead);

		BlueprintCall[] memory calls = new BlueprintCall[](1);
		calls[0] = BlueprintCall(
			from,
			address(native),
			abi.encode(to, amount),
			postChecksum ?
				keccak256(abi.encodePacked(NULL_HASH, keccak256(abi.encodePacked(uint256(0), amount)), NULL_HASH, NULL_HASH)) :
				bytes32(0)
		);

		uint256 balanceBefore = to.balance;

		vm.prank(from);
		manager.cook(address(0), calls);

		assertEq(balanceBefore + amount, to.balance);
	}

	function test_emptyCook() public {
		BlueprintCall[] memory calls = new BlueprintCall[](0);

		manager.cook(address(0), calls);
	}

	// function getLinearCliffVestingPosition(
	// 	uint256 id,
	// 	uint256 total,
	// 	uint256 unclaimed,
	// 	bytes memory params
	// ) public view returns (uint256 tokenId, uint256 count) {
	// 	if (unclaimed == 0)
	// 		return (0, 0);
	// 	count = gcd(total, unclaimed);
	// 	tokenId = HashLib.hash(
	// 		address(vesting),
	// 		uint256(keccak256(abi.encodePacked(
	// 			id,
	// 			total / count,
	// 			unclaimed / count,
	// 			address(schedule),
	// 			params
	// 		)))
	// 	);
	// }

	// function redeemMaxLinearCliffVesting(
	// 	address from,
	// 	uint256 id,
	// 	uint256 total,
	// 	uint256 unclaimed,
	// 	bytes memory params
	// ) public returns (uint256 newPosId, uint256 newPosBalance) {
	// 	BlueprintCall[] memory calls = new BlueprintCall[](1);
	// 	calls[0] = BlueprintCall(
	// 		from,
	// 		address(vesting),
	// 		abi.encode(
	// 			id,
	// 			total,
	// 			unclaimed,
	// 			address(schedule),
	// 			params,
	// 			total,
	// 			0
	// 		),
	// 		bytes32(0)
	// 	);
	// 	vm.prank(from);
	// 	manager.cook(address(0), calls);

	// 	return getLinearCliffVestingPosition(id, total, unclaimed, params);
	// }

	// function test_vesting(
	// 	address from,
	// 	uint256 amount,
	// 	uint256 batch,
	// 	uint256 measureTimestamp,
	// 	bool noSchedule
	// ) public {
	// 	vm.assume(from != address(vesting));
	// 	vm.assume(batch > 1);
	// 	vm.assume(amount > 0);

	// 	unchecked {
	// 		// amount * batch doesn't overflow
	// 		vm.assume(amount * batch / batch == amount);
	// 		vm.assume(amount * batch * 1000 / 1000 == amount * batch);
	// 	}
	// 	// vm.assume(amount == 10);
	// 	// vm.assume(batch == 2);
	// 	uint256 id = test_wrapNative(from, batch * amount);

	// 	// add zero variable so that the compiler will make runtime actually save
	// 	// these variables and not derive at runtime while the timestamp changes
	// 	uint256 zero = noSchedule ? 0 : 1;
	// 	zero = zero * zero - zero;
	// 	uint256 start = block.timestamp + 1000 + zero;
	// 	uint256 end = block.timestamp + 2000 + zero;
	// 	uint256 cliff = block.timestamp + 1250 + zero;
	// 	console2.log(cliff);
	// 	bytes memory params = abi.encode(start, end, cliff);

	// 	vm.assume(measureTimestamp >= start);

	// 	scheduledCalls.push(BlueprintCall(
	// 		from,
	// 		address(vesting),
	// 		abi.encode(
	// 			id,
	// 			amount * batch,
	// 			0,
	// 			address(schedule),
	// 			params,
	// 			batch,
	// 			batch / 2
	// 		),
	// 		bytes32(0)
	// 	));

	// 	uint256 vestingId;
	// 	uint256 balance;
	// 	if (noSchedule) {
	// 		vm.prank(from);
	// 		manager.cook(address(0), scheduledCalls);
	// 		scheduledCalls = new BlueprintCall[](0);

	// 		(vestingId, balance) = getLinearCliffVestingPosition(
	// 			id,
	// 			amount * batch,
	// 			amount * (batch / 2),
	// 			params
	// 		);

	// 		assertEq(manager.balanceOf(from, vestingId), balance);
	// 	}

	// 	// now, let's deposit the full batch
	// 	scheduledCalls.push(BlueprintCall(
	// 		from,
	// 		address(vesting),
	// 		abi.encode(
	// 			id,
	// 			amount * batch,
	// 			amount * (batch / 2),
	// 			address(schedule),
	// 			params,
	// 			batch,
	// 			batch
	// 		),
	// 		bytes32(0)
	// 	));

	// 	vm.prank(from);
	// 	manager.cook(address(0), scheduledCalls);
	// 	scheduledCalls = new BlueprintCall[](0);

	// 	(vestingId, balance) = getLinearCliffVestingPosition(
	// 		id,
	// 		amount * batch,
	// 		amount * batch,
	// 		params
	// 	);

	// 	assertEq(manager.balanceOf(from, vestingId), balance);
	// 	console2.log("after full deposit the balance is", manager.balanceOf(from, id));
	// 	assertEq(manager.balanceOf(from, id), 0, "didn't use up all tokens");

	// 	vm.warp(block.timestamp + 1000);

	// 	redeemMaxLinearCliffVesting(
	// 		from,
	// 		id,
	// 		amount * batch,
	// 		amount * batch,
	// 		params
	// 	);

	// 	// make sure that the operation didn't do anything – we can't decrease
	// 	// the vesting position just yet
	// 	assertEq(manager.balanceOf(from, vestingId), balance);

	// 	vm.warp(measureTimestamp);
	// 	redeemMaxLinearCliffVesting(
	// 		from,
	// 		id,
	// 		amount * batch,
	// 		amount * batch,
	// 		params
	// 	);

	// 	(vestingId, balance) = getLinearCliffVestingPosition(
	// 		id,
	// 		amount * batch,
	// 		amount * batch - schedule.getVestedTokens(
	// 			amount * batch,
	// 			params
	// 		),
	// 		params
	// 	);

	// 	console2.log("measure:", measureTimestamp);
	// 	console2.log("cliff:", cliff);
	// 	console2.log("timestamp:", block.timestamp);
	// 	console2.log("end:", end);
	// 	console2.log("start:", start);

	// 	assertEq(manager.balanceOf(from, vestingId), balance);
	// 	assertEq(
	// 		manager.balanceOf(from, id),
	// 		measureTimestamp < cliff ?
	// 			0 :
	// 			(measureTimestamp > end ?
	// 				amount * batch :
	// 				amount * batch * (measureTimestamp - start) / 1000)
	// 	);
	// }

	function test_erc20Wrap(address from, address to, uint256 amount) public returns (uint256 id) {
		vm.assume(amount != type(uint256).max);
		vm.assume(from != address(erc20wrapper));
		id = HashLib.hash(address(erc20wrapper), uint256(uint160(address(erc20))));
		erc20.mint(address(from), amount);

		vm.startPrank(from);
		erc20.approve(address(erc20wrapper), amount);
		erc20wrapper.deposit(address(erc20), to, 0, amount);
		vm.stopPrank();

		assertEq(erc20.balanceOf(address(erc20wrapper)), amount);
		assertEq(manager.balanceOf(to, id), amount);
	}

	function test_erc20Withdraw(address from, address to, uint256 amount) public {
		vm.assume(to != address(erc20wrapper));
		uint256 id = test_erc20Wrap(from, from, amount);
		BlueprintCall[] memory calls = new BlueprintCall[](1);
		calls[0] = BlueprintCall(
			from,
			address(erc20wrapper),
			abi.encode(
				erc20,
				to,
				amount
			),
			bytes32(0)
		);
		vm.prank(from);
		manager.cook(address(0), calls);

		assertEq(erc20.balanceOf(address(erc20wrapper)), 0);
		assertEq(erc20.balanceOf(to), amount);
		assertEq(manager.balanceOf(from, id), 0);
	}

	function test_basket(address from, uint256 amount0, uint256 amount1) public {
		vm.assume(amount0 != 0);
		vm.assume(amount1 != 0);
		uint256 nativeId = test_wrapNative(from, amount0);
		uint256 erc20Id = test_erc20Wrap(from, from, amount1);

		uint256 outputAmount = gcd(amount0, amount1);

		uint256[] memory ids = new uint256[](2);
		ids[0] = nativeId;
		ids[1] = erc20Id;
		uint256[] memory amounts = new uint256[](2);
		amounts[0] = amount0;
		amounts[1] = amount1;

		BlueprintCall[] memory calls = new BlueprintCall[](1);
		calls[0] = BlueprintCall(
			from,
			address(basket),
			abi.encode(
				true,
				ids,
				amounts
			),
			bytes32(0)
		);
		vm.prank(from);
		manager.cook(address(0), calls);

		for (uint256 i = 0; i < amounts.length; i++)
			amounts[i] /= outputAmount;

		uint256 id = HashLib.hash(
			address(basket),
			uint256(keccak256(abi.encodePacked(
				ids,
				amounts
			)))
		);

		assertEq(manager.balanceOf(address(basket), nativeId), amount0);
		assertEq(manager.balanceOf(address(basket), erc20Id), amount1);
		assertEq(manager.balanceOf(from, id), outputAmount);
	}

	function test_transferFrom(
		address from,
		address sender,
		uint256 amount,
		bool setApproval,
		bool setOperator
	) public {
		manager.mint(from, 0, amount);
		uint256 id = HashLib.hash(address(this), 0);

		vm.startPrank(from);
		if (setApproval)
			manager.approve(sender, id, amount);

		manager.setOperator(sender, setOperator);
		vm.stopPrank();

		bool willFail = !setApproval &&
			!setOperator &&
			from != sender &&
			amount != 0;

		vm.prank(sender);
		if (willFail)
			vm.expectRevert();
		manager.transferFrom(from, address(this), id, amount);

		if (!willFail)
			assertEq(manager.balanceOf(address(this), id), amount);
	}
}
