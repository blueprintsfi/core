// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {BlueprintManager} from "../src/BlueprintManager.sol";

import "forge-std/console.sol"; 

import {Mock_ERC1155Blueprint} from "./mock/Mock_ERC1155Blueprint.sol";

contract ERC1155Wrapper_Gas is Test {
	error NoFlashAccountingActive();

	BlueprintManager manager = new BlueprintManager();
	Mock_ERC1155Blueprint erc1155wrapper = new Mock_ERC1155Blueprint(manager);

	function setUp() external {
		vm.deal(address(this), type(uint).max);
	}

	function test_arrayDecodeWithAssemblyAndCallData(        
		address erc1155,
		address to,
		uint256[] memory ids,
		uint256[] memory amounts,
        bytes memory data
    ) public {
        bytes memory encodedData = abi.encode(erc1155, to, ids, amounts, data);
		(
            address erc1155New,
            address toNew,
            uint256[] memory idsNew,
            uint256[] memory amountsNew,
            bytes memory dataNew
	    ) = erc1155wrapper.executeActionNew(encodedData);
		(
            address erc1155Old,
            address toOld,
            uint256[] memory idsOld,
            uint256[] memory amountsOld,
            bytes memory dataOld
	    ) = erc1155wrapper.executeActionOld(encodedData);
		assertEq(erc1155, erc1155Old);
		assertEq(to, toOld);
		assertEq(ids, idsOld);
		assertEq(amounts, amountsOld);
		assertEq(data, dataOld);
		assertEq(erc1155, erc1155New);
		assertEq(to, toNew);
		assertEq(ids, idsNew);
		assertEq(amounts, amountsNew);
		assertEq(data, dataNew);
	}
}
