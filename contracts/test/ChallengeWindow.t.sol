// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/ChallengeWindow.sol";
import "../src/ClaimRegistry.sol";
import "../src/BondEscrow.sol";
import "../src/BondCalculator.sol";

contract MockUSDCW is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount; balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
    function totalSupply() external pure returns (uint256) { return type(uint256).max; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

contract ChallengeWindowTest is Test {
    ChallengeWindow challengeWindow;
    ClaimRegistry registry;
    BondEscrow escrow;
    BondCalculator calculator;
    MockUSDCW usdc;

    address admin      = address(0xA0);
    address submitter  = address(0xA2);
    address challenger = address(0xA3);
    address oracleRouter = address(0xA4);
    address voterPool  = address(0xA5);
    address treasury   = address(0xA6);
    address noveltyGateSim = address(0xA7); // simulates NoveltyGate role

    bytes32 constant CONTENT_HASH = keccak256("challenge window test claim");
    uint16  constant COMPLEXITY   = 10_000;

    function setUp() public {
        usdc = new MockUSDCW();
        calculator = new BondCalculator(admin);
        escrow = new BondEscrow(address(usdc), treasury, admin);
        registry = new ClaimRegistry(admin, address(escrow), address(calculator));
        challengeWindow = new ChallengeWindow(admin, address(registry), address(usdc), treasury);

        vm.startPrank(admin);
        // ClaimRegistry wiring
        escrow.grantRole(escrow.CLAIM_REGISTRY_ROLE(), address(registry));
        registry.grantRole(registry.NOVELTY_GATE_ROLE(), noveltyGateSim);
        registry.grantRole(registry.ORACLE_ROUTER_ROLE(), address(challengeWindow));
        // ChallengeWindow wiring
        challengeWindow.grantRole(challengeWindow.ORACLE_ROUTER_ROLE(), oracleRouter);
        vm.stopPrank();

        // Fund submitter
        uint256 bond = calculator.calculateBond(0, COMPLEXITY);
        usdc.mint(submitter, bond);
        vm.prank(submitter);
        usdc.approve(address(escrow), bond);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _submitAndPend() internal returns (bytes32 claimId) {
        vm.prank(submitter);
        claimId = registry.submitClaim(CONTENT_HASH, ClaimRegistry.Domain.General, COMPLEXITY, bytes32(0));
        vm.prank(noveltyGateSim);
        registry.recordNoveltyResult(claimId, true);
    }

    function _submitPendAndOpen() internal returns (bytes32 claimId) {
        claimId = _submitAndPend();
        challengeWindow.openWindow(claimId);
    }

    function _fundChallenger(uint256 amount) internal {
        usdc.mint(challenger, amount);
        vm.prank(challenger);
        usdc.approve(address(challengeWindow), amount);
    }

    // ── openWindow ────────────────────────────────────────────────────────────

    function test_OpenWindow_PendingClaim() public {
        bytes32 claimId = _submitAndPend();
        uint256 before = block.timestamp;

        challengeWindow.openWindow(claimId);

        ChallengeWindow.Window memory w = challengeWindow.getWindow(claimId);
        assertEq(w.openedAt, before);
        assertEq(w.expiresAt, before + 2 hours);
        assertEq(w.challenger, address(0));
        assertFalse(w.finalized);
    }

    function test_OpenWindow_NotPending_Reverts() public {
        vm.prank(submitter);
        bytes32 claimId = registry.submitClaim(
            keccak256("not pending"), ClaimRegistry.Domain.General, COMPLEXITY, bytes32(0)
        );
        // Claim is still Submitted, not Pending
        vm.expectRevert("ChallengeWindow: claim not pending");
        challengeWindow.openWindow(claimId);
    }

    function test_OpenWindow_AlreadyOpen_Reverts() public {
        bytes32 claimId = _submitAndPend();
        challengeWindow.openWindow(claimId);
        vm.expectRevert("ChallengeWindow: window already open");
        challengeWindow.openWindow(claimId);
    }

    // ── challenge ─────────────────────────────────────────────────────────────

    function test_Challenge_WithinWindow_MarksDisputed() public {
        bytes32 claimId = _submitPendAndOpen();
        uint256 bond = 50e6;
        _fundChallenger(bond);

        vm.prank(challenger);
        challengeWindow.challenge(claimId, bond);

        // Claim should be Disputed
        assertEq(uint8(registry.getClaim(claimId).status), uint8(ClaimRegistry.Status.Disputed));

        ChallengeWindow.Window memory w = challengeWindow.getWindow(claimId);
        assertEq(w.challenger, challenger);
        assertEq(w.challengerBond, bond);
        assertEq(usdc.balanceOf(address(challengeWindow)), bond);
    }

    function test_Challenge_AfterExpiry_Reverts() public {
        bytes32 claimId = _submitPendAndOpen();
        _fundChallenger(50e6);

        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(challenger);
        vm.expectRevert("ChallengeWindow: window expired");
        challengeWindow.challenge(claimId, 50e6);
    }

    function test_Challenge_ZeroBond_Reverts() public {
        bytes32 claimId = _submitPendAndOpen();

        vm.prank(challenger);
        vm.expectRevert("ChallengeWindow: zero bond");
        challengeWindow.challenge(claimId, 0);
    }

    function test_Challenge_AlreadyChallenged_Reverts() public {
        bytes32 claimId = _submitPendAndOpen();
        _fundChallenger(100e6);

        vm.prank(challenger);
        challengeWindow.challenge(claimId, 50e6);

        vm.prank(challenger);
        vm.expectRevert("ChallengeWindow: already challenged");
        challengeWindow.challenge(claimId, 50e6);
    }

    function test_Challenge_NoWindowOpen_Reverts() public {
        bytes32 claimId = _submitAndPend();

        _fundChallenger(50e6);
        vm.prank(challenger);
        vm.expectRevert("ChallengeWindow: no window open");
        challengeWindow.challenge(claimId, 50e6);
    }

    // ── finalizeUnchallenged ──────────────────────────────────────────────────

    function test_FinalizeUnchallenged_AfterExpiry_ResolvesVerified() public {
        bytes32 claimId = _submitPendAndOpen();

        vm.warp(block.timestamp + 2 hours);
        challengeWindow.finalizeUnchallenged(claimId);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Verified));
        assertEq(c.confidenceScore, 100);

        assertTrue(challengeWindow.getWindow(claimId).finalized);
    }

    function test_FinalizeUnchallenged_BeforeExpiry_Reverts() public {
        bytes32 claimId = _submitPendAndOpen();

        vm.warp(block.timestamp + 2 hours - 1);
        vm.expectRevert("ChallengeWindow: window not expired");
        challengeWindow.finalizeUnchallenged(claimId);
    }

    function test_FinalizeUnchallenged_WithChallenger_Reverts() public {
        bytes32 claimId = _submitPendAndOpen();
        _fundChallenger(50e6);

        vm.prank(challenger);
        challengeWindow.challenge(claimId, 50e6);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert("ChallengeWindow: has challenger");
        challengeWindow.finalizeUnchallenged(claimId);
    }

    function test_FinalizeUnchallenged_AlreadyFinalized_Reverts() public {
        bytes32 claimId = _submitPendAndOpen();

        vm.warp(block.timestamp + 2 hours);
        challengeWindow.finalizeUnchallenged(claimId);

        vm.expectRevert("ChallengeWindow: already finalized");
        challengeWindow.finalizeUnchallenged(claimId);
    }

    // ── releaseChallengerBond ─────────────────────────────────────────────────

    function test_ReleaseChallengerBond_TransfersToChallenger() public {
        bytes32 claimId = _submitPendAndOpen();
        uint256 bond = 100e6;
        _fundChallenger(bond);

        vm.prank(challenger);
        challengeWindow.challenge(claimId, bond);

        uint256 before = usdc.balanceOf(challenger);

        vm.prank(oracleRouter);
        challengeWindow.releaseChallengerBond(claimId);

        assertEq(usdc.balanceOf(challenger), before + bond);
        assertEq(usdc.balanceOf(address(challengeWindow)), 0);
        assertEq(challengeWindow.getWindow(claimId).challengerBond, 0);
    }

    function test_ReleaseChallengerBond_Unauthorized_Reverts() public {
        bytes32 claimId = _submitPendAndOpen();
        uint256 bond = 50e6;
        _fundChallenger(bond);

        vm.prank(challenger);
        challengeWindow.challenge(claimId, bond);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        challengeWindow.releaseChallengerBond(claimId);
    }

    // ── slashChallengerBond ───────────────────────────────────────────────────

    function test_SlashChallengerBond_SplitsBond() public {
        bytes32 claimId = _submitPendAndOpen();
        uint256 bond = 100e6;
        _fundChallenger(bond);

        vm.prank(challenger);
        challengeWindow.challenge(claimId, bond);

        uint256 submitterBefore = usdc.balanceOf(submitter);
        uint256 voterBefore     = usdc.balanceOf(voterPool);
        uint256 treasuryBefore  = usdc.balanceOf(treasury);

        vm.prank(oracleRouter);
        challengeWindow.slashChallengerBond(claimId, voterPool);

        assertEq(usdc.balanceOf(submitter),  submitterBefore + 60e6);
        assertEq(usdc.balanceOf(voterPool),  voterBefore     + 20e6);
        assertEq(usdc.balanceOf(treasury),   treasuryBefore  + 20e6);
        assertEq(usdc.balanceOf(address(challengeWindow)), 0);
        assertEq(challengeWindow.getWindow(claimId).challengerBond, 0);
    }

    function test_SlashChallengerBond_NoBond_Reverts() public {
        bytes32 claimId = _submitPendAndOpen();

        vm.prank(oracleRouter);
        vm.expectRevert("ChallengeWindow: no challenger bond");
        challengeWindow.slashChallengerBond(claimId, voterPool);
    }

    // ── isWindowOpen ──────────────────────────────────────────────────────────

    function test_IsWindowOpen_States() public {
        bytes32 claimId = _submitAndPend();

        assertFalse(challengeWindow.isWindowOpen(claimId)); // not opened yet

        challengeWindow.openWindow(claimId);
        assertTrue(challengeWindow.isWindowOpen(claimId));  // open

        vm.warp(block.timestamp + 2 hours);
        assertFalse(challengeWindow.isWindowOpen(claimId)); // expired
    }

    // ── governance ────────────────────────────────────────────────────────────

    function test_SetWindowDuration_Admin() public {
        vm.prank(admin);
        challengeWindow.setWindowDuration(4 hours);
        assertEq(challengeWindow.windowDuration(), 4 hours);
    }

    function test_SetWindowDuration_OutOfRange_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("ChallengeWindow: duration out of range");
        challengeWindow.setWindowDuration(30 minutes); // below MIN

        vm.prank(admin);
        vm.expectRevert("ChallengeWindow: duration out of range");
        challengeWindow.setWindowDuration(31 days); // above MAX
    }

    function test_SetTreasury_Admin() public {
        address newTreasury = address(0xBEEF);
        vm.prank(admin);
        challengeWindow.setTreasury(newTreasury);
        assertEq(challengeWindow.treasury(), newTreasury);
    }

    function test_SetTreasury_ZeroAddress_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("ChallengeWindow: zero address");
        challengeWindow.setTreasury(address(0));
    }
}
