// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BondEscrow.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract BondEscrowTest is Test {
    BondEscrow escrow;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address claimRegistry = makeAddr("claimRegistry");
    address oracleRouter = makeAddr("oracleRouter");
    address submitter = makeAddr("submitter");
    address challenger = makeAddr("challenger");
    address voterPool = makeAddr("voterPool");

    bytes32 constant CLAIM_ID = keccak256("claim1");
    uint256 constant BOND = 100e6;

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new BondEscrow(address(usdc), treasury, admin);

        bytes32 claimRegistryRole = escrow.CLAIM_REGISTRY_ROLE();
        bytes32 oracleRouterRole = escrow.ORACLE_ROUTER_ROLE();

        vm.startPrank(admin);
        escrow.grantRole(claimRegistryRole, claimRegistry);
        escrow.grantRole(oracleRouterRole, oracleRouter);
        vm.stopPrank();

        usdc.mint(submitter, BOND);
        vm.prank(submitter);
        usdc.approve(address(escrow), BOND);
    }

    function test_LockBond() public {
        vm.prank(claimRegistry);
        escrow.lockBond(CLAIM_ID, submitter, BOND);

        assertEq(escrow.lockedBond(CLAIM_ID), BOND);
        assertEq(escrow.bondHolder(CLAIM_ID), submitter);
        assertEq(usdc.balanceOf(address(escrow)), BOND);
    }

    function test_ReleaseBond() public {
        vm.prank(claimRegistry);
        escrow.lockBond(CLAIM_ID, submitter, BOND);

        vm.prank(oracleRouter);
        escrow.releaseBond(CLAIM_ID);

        assertEq(escrow.lockedBond(CLAIM_ID), 0);
        assertEq(usdc.balanceOf(submitter), BOND);
    }

    function test_SlashBond() public {
        vm.prank(claimRegistry);
        escrow.lockBond(CLAIM_ID, submitter, BOND);

        vm.prank(oracleRouter);
        escrow.slashBond(CLAIM_ID, challenger, voterPool);

        assertEq(usdc.balanceOf(challenger), (BOND * 6000) / 10_000);
        assertEq(usdc.balanceOf(voterPool), (BOND * 2000) / 10_000);
        assertEq(usdc.balanceOf(treasury), (BOND * 2000) / 10_000);
    }

    function test_DoubleLockReverts() public {
        vm.prank(claimRegistry);
        escrow.lockBond(CLAIM_ID, submitter, BOND);

        usdc.mint(submitter, BOND);
        vm.prank(submitter);
        usdc.approve(address(escrow), BOND);

        vm.prank(claimRegistry);
        vm.expectRevert("BondEscrow: bond already locked");
        escrow.lockBond(CLAIM_ID, submitter, BOND);
    }
}
