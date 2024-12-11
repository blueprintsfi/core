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

	function test_arrayDecodeWithAssemblyAndCallData() public {
		(
            address erc1155,
            address to,
            uint256[] memory ids,
            uint256[] memory amounts,
            bytes memory data
	    ) = erc1155wrapper.executeActionNew(_getEncodedActionData());
		(
            address erc1155Old,
            address toOld,
            uint256[] memory idsOld,
            uint256[] memory amountsOld,
            bytes memory dataOld
	    ) = erc1155wrapper.executeActionOld(_getEncodedActionData());
		assertEq(erc1155, erc1155Old);
		assertEq(to, toOld);
		assertEq(ids, idsOld);
		assertEq(amounts, amountsOld);
		assertEq(data, dataOld);
	}
    
    function _getEncodedActionData() internal pure returns(bytes memory){
        address erc1155 = 0xe6dAed993cFC56aaC97c9a19DE7E9f8c00e46208;
        address to = 0xe6dAed993cFC56aaC97c9a19DE7E9f8c00e46208;
        uint256[] memory ids = new uint256[](10);
        uint256[] memory amounts = new uint256[](10);
        bytes memory data = "abc";

        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        ids[3] = 4;
        ids[4] = 5;
        ids[5] = 6;
        ids[6] = 7;
        ids[7] = 8;
        ids[8] = 9;
        ids[9] = 10;

        amounts[0] = 100;
        amounts[1] = 200;
        amounts[2] = 300;
        amounts[3] = 400;
        amounts[4] = 500;
        amounts[5] = 600;
        amounts[6] = 700;
        amounts[7] = 800;
        amounts[8] = 900;
        amounts[9] = 1000;

        bytes memory encodedData = abi.encode(erc1155, to, ids, amounts, data);
        return encodedData;
    }
}
