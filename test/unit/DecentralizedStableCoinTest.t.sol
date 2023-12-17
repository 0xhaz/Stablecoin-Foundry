// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;

    address USER = makeAddr("user");

    function setUp() public {
        dsc = new DecentralizedStableCoin();
    }

    function test_mint() public {
        dsc.mint(address(this), 100);
        assertEq(dsc.balanceOf(address(this)), 100);
    }

    function test_burn() public {
        dsc.mint(address(this), 100);
        dsc.burn(50);
        assertEq(dsc.balanceOf(address(this)), 50);
    }
}
