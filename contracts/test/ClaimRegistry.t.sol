// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/ClaimRegistry.sol";
import "../src/BondEscrow.sol";
import "../src/BondCalculator.sol";

contract MockUSDC2 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount; balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
}

contract ClaimRegistryTest is Test {
    ClaimRegistry registry;
    BondEscrow escrow;
    BondCalculator calc;
    MockUSDC2 usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address submitter = makeAddr("submitter");
    address noveltyGate = makeAddr("noveltyGate");
    address oracleRouter = makeAddr("oracleRouter");

    bytes32 constant CONTENT_HASH = keccak256("claim content");
    uint16 constant COMPLEXITY_LOW = 10_000;

    function setUp() public {
        usdc = new MockUSDC2();
        calc = new BondCalculator(admin);
        escrow = new BondEscrow(address(usdc), treasury, admin);
        registry = new ClaimRegistry(admin, address(escrow), address(calc));

        vm.startPrank(admin);
        escrow.grantRole(escrow.CLAIM_REGISTRY_ROLE(), address(registry));
        escrow.grantRole(escrow.ORACLE_ROUTER_ROLE(), oracleRouter);
        registry.grantRole(registry.NOVELTY_GATE_ROLE(), noveltyGate);
        registry.grantRole(registry.ORACLE_ROUTER_ROLE(), oracleRouter);
        vm.stopPrank();

        usdc.mint(submitter, 1000e6);
        vm.prank(submitter);
        usdc.approve(address(escrow), 1000e6);
    }

    function test_SubmitClaim() public {
        vm.prank(submitter);
        bytes32 claimId = registry.submitClaim(
            CONTENT_HASH,
            ClaimRegistry.Domain.General,
            COMPLEXITY_LOW,
            bytes32(0)
        );

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(c.submitter, submitter);
        assertEq(c.contentHash, CONTENT_HASH);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Submitted));
        assertEq(c.bond, 100e6);
    }

    function test_DuplicateContentReverts() public {
        vm.prank(submitter);
        registry.submitClaim(CONTENT_HASH, ClaimRegistry.Domain.General, COMPLEXITY_LOW, bytes32(0));

        usdc.mint(submitter, 1000e6);
        vm.prank(submitter);
        usdc.approve(address(escrow), 1000e6);

        vm.prank(submitter);
        vm.expectRevert("ClaimRegistry: duplicate content");
        registry.submitClaim(CONTENT_HASH, ClaimRegistry.Domain.General, COMPLEXITY_LOW, bytes32(0));
    }

    function test_NoveltyPassedMovesPending() public {
        vm.prank(submitter);
        bytes32 claimId = registry.submitClaim(CONTENT_HASH, ClaimRegistry.Domain.General, COMPLEXITY_LOW, bytes32(0));

        vm.prank(noveltyGate);
        registry.recordNoveltyResult(claimId, true);

        assertEq(uint8(registry.getClaim(claimId).status), uint8(ClaimRegistry.Status.Pending));
    }

    function test_NoveltyFailedMovesRejected() public {
        vm.prank(submitter);
        bytes32 claimId = registry.submitClaim(CONTENT_HASH, ClaimRegistry.Domain.General, COMPLEXITY_LOW, bytes32(0));

        vm.prank(noveltyGate);
        registry.recordNoveltyResult(claimId, false);

        assertEq(uint8(registry.getClaim(claimId).status), uint8(ClaimRegistry.Status.Rejected));
    }

    function test_ResolveUnchallenged() public {
        vm.prank(submitter);
        bytes32 claimId = registry.submitClaim(CONTENT_HASH, ClaimRegistry.Domain.General, COMPLEXITY_LOW, bytes32(0));

        vm.prank(noveltyGate);
        registry.recordNoveltyResult(claimId, true);

        vm.prank(oracleRouter);
        registry.resolveUnchallenged(claimId, 85);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Verified));
        assertEq(c.confidenceScore, 85);
    }

    function test_DailyCap() public {
        vm.prank(admin);
        registry.setDailySubmissionCap(2);

        usdc.mint(submitter, 10_000e6);
        vm.prank(submitter);
        usdc.approve(address(escrow), 10_000e6);

        vm.startPrank(submitter);
        registry.submitClaim(keccak256("c1"), ClaimRegistry.Domain.General, COMPLEXITY_LOW, bytes32(0));
        registry.submitClaim(keccak256("c2"), ClaimRegistry.Domain.General, COMPLEXITY_LOW, bytes32(0));
        vm.expectRevert("ClaimRegistry: daily cap reached");
        registry.submitClaim(keccak256("c3"), ClaimRegistry.Domain.General, COMPLEXITY_LOW, bytes32(0));
        vm.stopPrank();
    }
}
