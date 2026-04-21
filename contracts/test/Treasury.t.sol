// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/Treasury.sol";

contract MockUSDCTreasury {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function totalSupply() external pure returns (uint256) { return type(uint256).max; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

contract TreasuryTest is Test {
    Treasury         tsy;
    MockUSDCTreasury usdc;

    address admin      = address(0xA0);
    address foundation = address(0xA1);
    address executor   = address(0xA2);
    address user       = address(0xA3);
    address recipient  = address(0xA4);

    bytes32 constant PROPOSAL_HASH = keccak256("proposal-1");

    function setUp() public {
        usdc = new MockUSDCTreasury();
        tsy  = new Treasury(admin, foundation, address(usdc));

        vm.startPrank(admin);
        tsy.grantRole(tsy.EXECUTOR_ROLE(), executor);
        vm.stopPrank();

        // Fund the treasury
        usdc.mint(address(tsy), 1_000_000e6); // 1M USDC
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    function test_VetoExpiresAt_IsDeployPlusTwoYears() public view {
        assertEq(tsy.vetoExpiresAt(), block.timestamp + 730 days);
    }

    // ── Deposit ───────────────────────────────────────────────────────────────

    function test_Deposit_TransfersUSDC() public {
        usdc.mint(user, 500e6);
        vm.prank(user);
        usdc.approve(address(tsy), 500e6);

        vm.prank(user);
        tsy.deposit(500e6);

        assertEq(usdc.balanceOf(address(tsy)), 1_000_000e6 + 500e6);
    }

    function test_Deposit_EmitsEvent() public {
        usdc.mint(user, 100e6);
        vm.prank(user);
        usdc.approve(address(tsy), 100e6);

        vm.expectEmit(true, false, false, true);
        emit Treasury.Deposit(user, 100e6);
        vm.prank(user);
        tsy.deposit(100e6);
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────

    function test_Withdraw_ExecutorRole() public {
        vm.prank(executor);
        tsy.withdraw(recipient, 100e6, PROPOSAL_HASH);

        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function test_Withdraw_Unauthorized_Reverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        tsy.withdraw(recipient, 100e6, PROPOSAL_HASH);
    }

    function test_Withdraw_ZeroRecipient_Reverts() public {
        vm.prank(executor);
        vm.expectRevert("Treasury: zero recipient");
        tsy.withdraw(address(0), 100e6, PROPOSAL_HASH);
    }

    function test_Withdraw_VetoedProposal_Reverts() public {
        vm.prank(foundation);
        tsy.veto(PROPOSAL_HASH);

        vm.prank(executor);
        vm.expectRevert("Treasury: proposal vetoed");
        tsy.withdraw(recipient, 100e6, PROPOSAL_HASH);
    }

    // ── Veto ──────────────────────────────────────────────────────────────────

    function test_Veto_FoundationRole_SetsFlag() public {
        vm.prank(foundation);
        tsy.veto(PROPOSAL_HASH);
        assertTrue(tsy.vetoed(PROPOSAL_HASH));
    }

    function test_Veto_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Treasury.ProposalVetoed(PROPOSAL_HASH);
        vm.prank(foundation);
        tsy.veto(PROPOSAL_HASH);
    }

    function test_Veto_Unauthorized_Reverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        tsy.veto(PROPOSAL_HASH);
    }

    function test_Veto_AfterExpiry_Reverts() public {
        vm.warp(tsy.vetoExpiresAt() + 1);
        vm.prank(foundation);
        vm.expectRevert("Treasury: veto power expired");
        tsy.veto(PROPOSAL_HASH);
    }

    // ── Buyback ───────────────────────────────────────────────────────────────

    function test_InitiateBuyback_WithinCap_EmitsEvent() public {
        // 10% of 1M = 100k
        vm.expectEmit(false, false, false, true);
        emit Treasury.BuybackInitiated(100_000e6);
        vm.prank(executor);
        tsy.initiateBuyback(100_000e6);
    }

    function test_InitiateBuyback_ExactlyCap_Succeeds() public {
        uint256 cap = 1_000_000e6 * tsy.BUYBACK_CAP_BPS() / tsy.BPS_DENOM();
        vm.prank(executor);
        tsy.initiateBuyback(cap); // should not revert
    }

    function test_InitiateBuyback_ExceedsCap_Reverts() public {
        uint256 cap = 1_000_000e6 * tsy.BUYBACK_CAP_BPS() / tsy.BPS_DENOM();
        vm.prank(executor);
        vm.expectRevert("Treasury: exceeds buyback cap");
        tsy.initiateBuyback(cap + 1);
    }

    function test_InitiateBuyback_ZeroAmount_Reverts() public {
        vm.prank(executor);
        vm.expectRevert("Treasury: zero amount");
        tsy.initiateBuyback(0);
    }

    function test_InitiateBuyback_Unauthorized_Reverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        tsy.initiateBuyback(1000e6);
    }

    // ── ETH rejection ─────────────────────────────────────────────────────────

    function test_ETH_Rejected() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok, bytes memory data) = address(tsy).call{value: 1 ether}("");
        assertFalse(ok);
        // revert message is "Treasury: ETH not accepted"
        assertGt(data.length, 0);
    }
}
