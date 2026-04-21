// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/NoveltyGate.sol";
import "../src/ClaimRegistry.sol";
import "../src/BondEscrow.sol";
import "../src/BondCalculator.sol";

// Minimal mock USDC for testing
contract MockUSDC2 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
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
    function totalSupply() external pure returns (uint256) { return type(uint256).max; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

contract NoveltyGateTest is Test {
    NoveltyGate noveltyGate;
    ClaimRegistry registry;
    BondEscrow escrow;
    BondCalculator calculator;
    MockUSDC2 usdc;

    address admin = address(0xA0);
    address snsOracle = address(0xA1);
    address submitter = address(0xA2);

    bytes32 constant CONTENT_HASH = keccak256("test claim content");
    bytes32 constant JUSTIFICATION_HASH = keccak256("justification json");

    function setUp() public {
        usdc = new MockUSDC2();
        calculator = new BondCalculator(admin);
        escrow = new BondEscrow(address(usdc), address(0xFEE), admin);
        registry = new ClaimRegistry(admin, address(escrow), address(calculator));

        noveltyGate = new NoveltyGate(admin, address(registry));

        // Wire roles
        vm.startPrank(admin);
        registry.grantRole(registry.NOVELTY_GATE_ROLE(), address(noveltyGate));
        escrow.grantRole(escrow.CLAIM_REGISTRY_ROLE(), address(registry));
        noveltyGate.grantRole(noveltyGate.SNS_ORACLE_ROLE(), snsOracle);
        vm.stopPrank();

        // Fund submitter and approve escrow
        uint256 bond = calculator.calculateBond(0, 10000); // General, Low
        usdc.mint(submitter, bond);
        vm.prank(submitter);
        usdc.approve(address(escrow), bond);
    }

    function _submitClaim() internal returns (bytes32 claimId) {
        vm.prank(submitter);
        claimId = registry.submitClaim(CONTENT_HASH, ClaimRegistry.Domain.General, 10000, bytes32(0));
    }

    function test_NovelClaim_PassesGate() public {
        bytes32 claimId = _submitClaim();

        vm.prank(snsOracle);
        noveltyGate.submitNoveltyResult(claimId, 7500, bytes32(0), JUSTIFICATION_HASH);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Pending));
        assertTrue(c.noveltyPassed);

        NoveltyGate.NoveltyRecord memory rec = noveltyGate.getNoveltyRecord(claimId);
        assertEq(rec.similarityBps, 7500);
        assertEq(rec.justificationHash, JUSTIFICATION_HASH);
        assertTrue(rec.processed);
    }

    function test_DuplicateClaim_FailsGate() public {
        bytes32 claimId = _submitClaim();

        bytes32 nearestId = bytes32(uint256(999));
        vm.prank(snsOracle);
        // Similarity 0.92 > threshold 0.90 → reject
        noveltyGate.submitNoveltyResult(claimId, 9200, nearestId, JUSTIFICATION_HASH);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Rejected));
        assertFalse(c.noveltyPassed);
    }

    function test_AtThreshold_Fails() public {
        bytes32 claimId = _submitClaim();

        vm.prank(snsOracle);
        // Exactly at threshold (9000) → reject (not strictly less than)
        noveltyGate.submitNoveltyResult(claimId, 9000, bytes32(0), JUSTIFICATION_HASH);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Rejected));
    }

    function test_JustBelowThreshold_Passes() public {
        bytes32 claimId = _submitClaim();

        vm.prank(snsOracle);
        noveltyGate.submitNoveltyResult(claimId, 8999, bytes32(0), JUSTIFICATION_HASH);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Pending));
    }

    function test_DoubleProcess_Reverts() public {
        bytes32 claimId = _submitClaim();

        vm.startPrank(snsOracle);
        noveltyGate.submitNoveltyResult(claimId, 7000, bytes32(0), JUSTIFICATION_HASH);
        vm.expectRevert("NoveltyGate: already processed");
        noveltyGate.submitNoveltyResult(claimId, 7000, bytes32(0), JUSTIFICATION_HASH);
        vm.stopPrank();
    }

    function test_UnauthorizedOracle_Reverts() public {
        bytes32 claimId = _submitClaim();

        vm.prank(address(0xBAD));
        vm.expectRevert();
        noveltyGate.submitNoveltyResult(claimId, 7000, bytes32(0), JUSTIFICATION_HASH);
    }

    function test_SetThreshold_UpdatesCorrectly() public {
        vm.prank(admin);
        noveltyGate.setRejectThreshold(8500);
        assertEq(noveltyGate.noveltyRejectThresholdBps(), 8500);
    }

    function test_SetThreshold_OutOfRange_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("NoveltyGate: threshold out of range");
        noveltyGate.setRejectThreshold(4999);

        vm.prank(admin);
        vm.expectRevert("NoveltyGate: threshold out of range");
        noveltyGate.setRejectThreshold(9901);
    }

    function test_InvalidSimilarityBps_Reverts() public {
        bytes32 claimId = _submitClaim();

        vm.prank(snsOracle);
        vm.expectRevert("NoveltyGate: invalid similarity bps");
        noveltyGate.submitNoveltyResult(claimId, 10001, bytes32(0), JUSTIFICATION_HASH);
    }
}
