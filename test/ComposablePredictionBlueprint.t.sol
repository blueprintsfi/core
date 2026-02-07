// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {BlueprintManager, BlueprintCall, HashLib} from "../src/BlueprintManager.sol";
import {ConstantOracle} from "../src/blueprints/oracleBased/oracle/ConstantOracle.sol";
import {ComposablePredictionBlueprint, Constraint, TokenParams} from "../src/blueprints/oracleBased/draft-ComposablePredictionBlueprint.sol";

library TokenLib {
	function setPrediction(address prediction) public {
		assembly ("memory-safe") {
			sstore(0, prediction)
		}
	}

	function _constrs() public returns (Constraint[] storage $) {
		assembly ("memory-safe") {
			mstore(0, 0x1337)
			// hash of length 2 doesn't collide with anything Solidity does
			$.slot := keccak256(0, 2)
			sstore($.slot, 0)
		}
	}

	function _arr() public returns (uint256[] storage $) {
		assembly ("memory-safe") {
			mstore(0, 0x6969)
			// hash of length 2 doesn't collide with anything Solidity does
			$.slot := keccak256(0, 2)
			sstore($.slot, 0)
		}
	}

	function predictionBlueprint() public view returns (address prediction) {
		assembly ("memory-safe") {
			prediction := sload(0)
		}
	}

	function removeConstraint(
		TokenParams memory params,
		bytes32 feed,
		bool mustExist
	) public returns (TokenParams memory) {
		Constraint[] storage constrs = _constrs();
		bool ok = false;
		for (uint256 i = 0; i < params.constraints.length; i++) {
			if (params.constraints[i].feedId == feed) {
				ok = true;
			} else {
				constrs.push(params.constraints[i]);
			}
		}
		require(ok || !mustExist, "Constraint must exist for removal, but didn't");

		return TokenParams(params.tokenId, constrs);
	}

	function removeConstraint(TokenParams memory params, bytes32 feed) public returns (TokenParams memory) {
		return removeConstraint(params, feed, true);
	}

	function getConstraint(
		TokenParams memory params,
		bytes32 feed
	) public pure returns (uint256 start, uint256 end, bool found) {
		for (uint256 i = 0; i < params.constraints.length; i++) {
			if (params.constraints[i].feedId == feed) {
				return (params.constraints[i].startRange, params.constraints[i].endRange, true);
			}
		}
		return (0, 0, false);
	}

	function setConstraint(TokenParams memory params, Constraint memory constraint) public returns (TokenParams memory) {
		return setConstraint(params, constraint.feedId, constraint.startRange, constraint.endRange);
	}

	function setConstraint(
		TokenParams memory params,
		bytes32 feed,
		uint256 start,
		uint256 end
	) public returns (TokenParams memory) {
		params = removeConstraint(params, feed, false);

		Constraint[] storage constrs = _constrs();
		bool done = false;
		for (uint256 i = 0; i < params.constraints.length; i++) {
			if (!done && params.constraints[i].feedId > feed) {
				constrs.push(Constraint(feed, start, end));
				done = true;
			}
			constrs.push(params.constraints[i]);
		}
		if (!done)
			constrs.push(Constraint(feed, start, end));

		return TokenParams(params.tokenId, constrs);
	}

	function getId(TokenParams memory params) public returns (uint256) {
		if (params.constraints.length == 0)
			return params.tokenId;
		uint256[] storage arr = _arr();
		arr.push(params.tokenId);
		for (uint256 i = 0; i < params.constraints.length; i++) {
			arr.push(uint256(params.constraints[i].feedId));
			arr.push(params.constraints[i].startRange);
			arr.push(params.constraints[i].endRange);
		}
		return HashLib.hash(predictionBlueprint(), uint256(keccak256(abi.encodePacked(arr))));
	}
}

using TokenLib for TokenParams;

contract PredictionTest is Test {
	BlueprintManager manager = new BlueprintManager();
	ConstantOracle oracle = new ConstantOracle();
	ComposablePredictionBlueprint prediction = new ComposablePredictionBlueprint(manager, oracle);

	uint256[] public arr;
	Constraint[] public constrs;

	uint256 immutable tokenId = HashLib.hash(address(this), 0);

	function setUp() external {
		vm.deal(address(this), type(uint).max);
		manager.mint(address(this), 0, 1e9 ether);
		TokenLib.setPrediction(address(prediction));
	}

	function callPrediction(bytes memory data) public {
		BlueprintCall[] memory calls = new BlueprintCall[](1);
		calls[0] = BlueprintCall(
			address(this),
			0,
			address(prediction),
			data,
			0
		);
		manager.cook(address(this), calls);
	}

	function mergeSplit(
		TokenParams memory params,
		uint256 amount,
		bytes32 feed,
		uint256 cut,
		bool merge
	) public {
		callPrediction(abi.encode(
			params,
			amount,
			feed,
			cut,
			1337, // anything
			merge,
			false
		));
	}

	function split(
		TokenParams memory params,
		uint256 amount,
		Constraint memory constraint
	) public {
		uint256 start = constraint.startRange;
		uint256 end = constraint.endRange;
		require(start != 0 || end != 0);
		if (start != 0) {
			mergeSplit(params, amount, constraint.feedId, start, false);
			params = params.setConstraint(constraint.feedId, start, 0);
		}

		if (end != 0)
			mergeSplit(params, amount, constraint.feedId, end, false);
	}

	function settle(
		TokenParams memory params,
		uint256 amount,
		bytes32 feed,
		bool reverse
	) public returns (uint256 id) {
		id = params.removeConstraint(feed).getId();
		(uint256 start, uint256 end, bool found) = params.getConstraint(feed);
		require(found, "constraint not found");

		callPrediction(abi.encode(
			params.removeConstraint(feed),
			amount,
			feed,
			start,
			end,
			!reverse,
			true
		));
	}

	function test_canCreateBasicPrediction(
		uint256 amount,
		uint256 cut
	) public {
		vm.assume(amount < 1e9 ether);
		vm.assume(cut != 0);
		bytes32 feedId = bytes32(HashLib.hash(address(this), 0));

		TokenParams memory params = TokenParams(tokenId, new Constraint[](0));

		mergeSplit(params, amount, feedId, cut, false);
		uint256 lowId = params.setConstraint(feedId, 0, cut).getId();
		uint256 highId = params.setConstraint(feedId, cut, 0).getId();
		assertEq(manager.balanceOf(address(this), tokenId), 1e9 ether - amount);
		assertEq(manager.balanceOf(address(this), lowId), amount);
		assertEq(manager.balanceOf(address(this), highId), amount);

		mergeSplit(params, amount, feedId, cut, true);
		assertEq(manager.balanceOf(address(this), tokenId), 1e9 ether);
		assertEq(manager.balanceOf(address(this), lowId), 0);
		assertEq(manager.balanceOf(address(this), highId), 0);
	}

	function test_canReedeemBasicPrediction(
		uint256 amount,
		uint256 cut,
		uint256 result
	) public {
		vm.assume(amount < 1e9 ether);
		vm.assume(cut != 0);

		bytes32 feedId = bytes32(HashLib.hash(address(this), 0));

		TokenParams memory params = TokenParams(tokenId, new Constraint[](0));
		mergeSplit(params, amount, feedId, cut, false);
		oracle.cache(0, result);

		settle(params.setConstraint(feedId, 0, cut), amount, feedId, false);
		uint256 received = result < cut ? amount : 0;
		assertEq(manager.balanceOf(address(this), params.getId()), 1e9 ether - amount + received);
		assertEq(manager.balanceOf(address(this), params.setConstraint(feedId, 0, cut).getId()), 0);
		assertEq(manager.balanceOf(address(this), params.setConstraint(feedId, cut, 0).getId()), amount);

		settle(params.setConstraint(feedId, cut, 0), amount, feedId, false);
		assertEq(manager.balanceOf(address(this), params.getId()), 1e9 ether);
		assertEq(manager.balanceOf(address(this), params.setConstraint(feedId, 0, cut).getId()), 0);
		assertEq(manager.balanceOf(address(this), params.setConstraint(feedId, cut, 0).getId()), 0);

		settle(params.setConstraint(feedId, cut, 0), amount, feedId, true);
		assertEq(manager.balanceOf(address(this), params.getId()), 1e9 ether - amount + received);
		assertEq(manager.balanceOf(address(this), params.setConstraint(feedId, 0, cut).getId()), 0);
		assertEq(manager.balanceOf(address(this), params.setConstraint(feedId, cut, 0).getId()), amount);

		settle(params.setConstraint(feedId, 0, cut), amount, feedId, true);
		assertEq(manager.balanceOf(address(this), params.getId()), 1e9 ether - amount);
		assertEq(manager.balanceOf(address(this), params.setConstraint(feedId, 0, cut).getId()), amount);
		assertEq(manager.balanceOf(address(this), params.setConstraint(feedId, cut, 0).getId()), amount);
	}

	function test_canSplit3Ways(
		Constraint[] memory previousConstraints,
		uint256 amount,
		uint256 cut1,
		uint256 cut2
	) public {
		// We do a lot of memory operations, not limiting this will cause Memory OOG at about 400-500
		vm.assume(previousConstraints.length < 50);
		vm.assume(amount < 1e9 ether);
		vm.assume(cut1 != 0 && (cut1 < cut2 || (cut1 != 0 && cut2 == 0)));

		bytes32 feed = bytes32(HashLib.hash(address(this), 0));

		TokenParams memory params = TokenParams(tokenId, new Constraint[](0));
		for (uint256 i = 0; i < previousConstraints.length; i++) {
			vm.assume(previousConstraints[i].feedId != feed);
			(,, bool found) = params.getConstraint(previousConstraints[i].feedId);
			vm.assume(!found);
			uint256 start = previousConstraints[i].startRange;
			uint256 end = previousConstraints[i].endRange;
			if (start > end && end != 0) {
				previousConstraints[i] = Constraint(previousConstraints[i].feedId, end, start);
				(start, end) = (end, start);
			}
			vm.assume(start < end || end == 0);
			vm.assume(start != 0 || end != 0);

			split(params, amount, previousConstraints[i]);
			params = params.setConstraint(previousConstraints[i]);
		}

		split(params, amount, Constraint(feed, cut1, cut2));
		if (cut1 != 0)
			assertEq(manager.balanceOf(address(this), params.setConstraint(feed, 0, cut1).getId()), amount);
		if (cut2 != 0)
			assertEq(manager.balanceOf(address(this), params.setConstraint(feed, cut2, 0).getId()), amount);
		assertEq(manager.balanceOf(address(this), params.setConstraint(feed, cut1, cut2).getId()), amount);

		if (cut2 != 0)
			mergeSplit(params.setConstraint(feed, cut1, 0), amount, feed, cut2, true);

		if (cut1 != 0)
			mergeSplit(params, amount, feed, cut1, true);

		assertEq(manager.balanceOf(address(this), params.getId()), previousConstraints.length == 0 ? 1e9 ether : amount);
	}
}
