// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Lender.sol";

contract LenderTest is Test {
    Lender public lender;

    function setUp() public {
        lender = new Lender();
    }

}
