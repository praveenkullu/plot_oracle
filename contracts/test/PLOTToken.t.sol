// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/PLOTToken.sol";

contract PLOTTokenTest is Test {
    PLOTToken token;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");
    address slasher = makeAddr("slasher");

    function setUp() public {
        token = new PLOTToken(admin, treasury);
    }

    function test_InitialSupply() public view {
        assertEq(token.totalSupply(), token.MAX_SUPPLY() / 5);
        assertEq(token.balanceOf(treasury), token.MAX_SUPPLY() / 5);
    }

    function test_Mint() public {
        vm.prank(admin);
        token.mint(user, 100e18);
        assertEq(token.balanceOf(user), 100e18);
    }

    function test_MintExceedsMaxSupply() public {
        uint256 maxSupply = token.MAX_SUPPLY();
        vm.prank(admin);
        vm.expectRevert("PLOTToken: max supply exceeded");
        token.mint(user, maxSupply);
    }

    function test_Slash() public {
        vm.prank(admin);
        token.mint(user, 1000e18);

        bytes32 slasherRole = token.SLASHER_ROLE();
        vm.prank(admin);
        token.grantRole(slasherRole, slasher);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(slasher);
        token.slash(user, 500e18);

        assertEq(token.balanceOf(user), 500e18);
        assertEq(token.totalSupply(), supplyBefore - 500e18);
        assertEq(token.totalSlashed(), 500e18);
    }

    function test_UnauthorizedMintReverts() public {
        vm.prank(user);
        vm.expectRevert();
        token.mint(user, 100e18);
    }
}
