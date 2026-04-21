// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/OracleRouter.sol";
import "../src/InternalVote.sol";
import "../src/ChallengeWindow.sol";
import "../src/ClaimRegistry.sol";
import "../src/BondEscrow.sol";
import "../src/BondCalculator.sol";
import "../src/ConfidenceScorer.sol";

contract MockUSDCOR is IERC20 {
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

contract OracleRouterTest is Test {
    OracleRouter     oracleRouter;
    InternalVote     internalVote;
    ChallengeWindow  challengeWindow;
    ClaimRegistry    registry;
    BondEscrow       escrow;
    BondCalculator   calculator;
    ConfidenceScorer scorer;
    MockUSDCOR       usdc;

    address admin         = address(0xA0);
    address submitter     = address(0xA2);
    address challenger    = address(0xA3);
    address voter1        = address(0xA4);
    address voter2        = address(0xA5);
    address voterPool     = address(0xA6);
    address treasury      = address(0xA7);
    address noveltyGateSim = address(0xA8);

    bytes32 constant CONTENT_HASH = keccak256("oracle router test claim");
    uint16  constant COMPLEXITY   = 10_000; // 1x → bond = $100 = 100e6

    uint256 submitterBond;      // 100e6
    uint256 challengerBond = 50e6;

    function setUp() public {
        usdc        = new MockUSDCOR();
        calculator  = new BondCalculator(admin);
        escrow      = new BondEscrow(address(usdc), treasury, admin);
        registry    = new ClaimRegistry(admin, address(escrow), address(calculator));
        challengeWindow = new ChallengeWindow(admin, address(registry), address(usdc), treasury);
        oracleRouter    = new OracleRouter(
            admin, address(registry), address(escrow), address(challengeWindow), voterPool
        );
        scorer       = new ConfidenceScorer(admin);
        internalVote = new InternalVote(admin, address(registry), address(oracleRouter), address(scorer), 2);

        vm.startPrank(admin);
        // ClaimRegistry wiring
        escrow.grantRole(escrow.CLAIM_REGISTRY_ROLE(), address(registry));
        registry.grantRole(registry.NOVELTY_GATE_ROLE(), noveltyGateSim);
        registry.grantRole(registry.ORACLE_ROUTER_ROLE(), address(challengeWindow)); // markDisputed + resolveUnchallenged
        registry.grantRole(registry.ORACLE_ROUTER_ROLE(), address(oracleRouter));   // resolveVerified/Rejected/finalizeDomain
        // BondEscrow + ChallengeWindow wiring for OracleRouter
        escrow.grantRole(escrow.ORACLE_ROUTER_ROLE(), address(oracleRouter));
        challengeWindow.grantRole(challengeWindow.ORACLE_ROUTER_ROLE(), address(oracleRouter));
        // InternalVote → OracleRouter
        oracleRouter.grantRole(oracleRouter.INTERNAL_VOTE_ROLE(), address(internalVote));
        // Voters
        internalVote.grantRole(internalVote.VOTER_ROLE(), voter1);
        internalVote.grantRole(internalVote.VOTER_ROLE(), voter2);
        vm.stopPrank();

        submitterBond = calculator.calculateBond(0, COMPLEXITY); // 100e6
        usdc.mint(submitter, submitterBond);
        vm.prank(submitter);
        usdc.approve(address(escrow), submitterBond);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _submitAndPend() internal returns (bytes32 claimId) {
        vm.prank(submitter);
        claimId = registry.submitClaim(CONTENT_HASH, ClaimRegistry.Domain.General, COMPLEXITY, bytes32(0));
        vm.prank(noveltyGateSim);
        registry.recordNoveltyResult(claimId, true);
    }

    function _submitPendAndChallenge() internal returns (bytes32 claimId) {
        claimId = _submitAndPend();
        challengeWindow.openWindow(claimId);
        usdc.mint(challenger, challengerBond);
        vm.prank(challenger);
        usdc.approve(address(challengeWindow), challengerBond);
        vm.prank(challenger);
        challengeWindow.challenge(claimId, challengerBond);
    }

    function _openVoteAndCastTwo(bytes32 claimId, bool v1Support, bool v2Support) internal {
        internalVote.openVote(claimId);
        vm.prank(voter1);
        internalVote.castVote(claimId, v1Support);
        vm.prank(voter2);
        internalVote.castVote(claimId, v2Support);
    }

    // ── executeResolution via InternalVote ────────────────────────────────────

    function test_SubmitterWins_ReleasesSubmitterBond_SlashesChallengerBond() public {
        bytes32 claimId = _submitPendAndChallenge();

        uint256 submitterBefore = usdc.balanceOf(submitter);
        uint256 voterPoolBefore = usdc.balanceOf(voterPool);
        uint256 treasuryBefore  = usdc.balanceOf(treasury);

        _openVoteAndCastTwo(claimId, true, true); // 2 for, 0 against → verified, score=100
        internalVote.finalizeVote(claimId);

        // submitter gets bond back (100e6) + 60% of challenger bond (30e6)
        assertEq(usdc.balanceOf(submitter),  submitterBefore + submitterBond + 30e6);
        // voterPool gets 20% of challenger bond (10e6)
        assertEq(usdc.balanceOf(voterPool),  voterPoolBefore + 10e6);
        // treasury gets 20% of challenger bond (10e6)
        assertEq(usdc.balanceOf(treasury),   treasuryBefore  + 10e6);
        assertEq(usdc.balanceOf(address(escrow)),          0);
        assertEq(usdc.balanceOf(address(challengeWindow)), 0);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Verified));
        assertEq(c.confidenceScore, 100);
        assertTrue(c.domainFinalized);
    }

    function test_ChallengerWins_SlashesSubmitterBond_ReleasesChallengerBond() public {
        bytes32 claimId = _submitPendAndChallenge();

        uint256 challengerBefore = usdc.balanceOf(challenger);
        uint256 voterPoolBefore  = usdc.balanceOf(voterPool);
        uint256 treasuryBefore   = usdc.balanceOf(treasury);

        _openVoteAndCastTwo(claimId, false, false); // 0 for, 2 against → rejected
        internalVote.finalizeVote(claimId);

        // challenger gets 60% of submitter bond (60e6) + own bond back (50e6) = 110e6
        assertEq(usdc.balanceOf(challenger),  challengerBefore + 60e6 + challengerBond);
        // voterPool gets 20% of submitter bond (20e6)
        assertEq(usdc.balanceOf(voterPool),   voterPoolBefore  + 20e6);
        // treasury gets 20% of submitter bond (20e6)
        assertEq(usdc.balanceOf(treasury),    treasuryBefore   + 20e6);
        assertEq(usdc.balanceOf(address(escrow)),          0);
        assertEq(usdc.balanceOf(address(challengeWindow)), 0);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Rejected));
        assertEq(c.confidenceScore, 0);
        assertTrue(c.domainFinalized);
    }

    function test_TieVote_ResolvesRejected() public {
        bytes32 claimId = _submitPendAndChallenge();
        _openVoteAndCastTwo(claimId, true, false); // 1 for, 1 against → tie → rejected
        internalVote.finalizeVote(claimId);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Rejected));
    }

    function test_ExecuteResolution_Unauthorized_Reverts() public {
        bytes32 claimId = _submitPendAndChallenge();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        oracleRouter.executeResolution(claimId, true, 90, ClaimRegistry.Domain.General);
    }

    // ── releaseSubmitterBond (unchallenged path) ───────────────────────────────

    function test_ReleaseSubmitterBond_AfterUnchallengedFinalization() public {
        bytes32 claimId = _submitAndPend();
        challengeWindow.openWindow(claimId);

        vm.warp(block.timestamp + 2 hours);
        challengeWindow.finalizeUnchallenged(claimId);

        uint256 submitterBefore = usdc.balanceOf(submitter);
        oracleRouter.releaseSubmitterBond(claimId);
        assertEq(usdc.balanceOf(submitter), submitterBefore + submitterBond);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_ReleaseSubmitterBond_NotVerified_Reverts() public {
        bytes32 claimId = _submitAndPend();
        vm.expectRevert("OracleRouter: claim not verified");
        oracleRouter.releaseSubmitterBond(claimId);
    }

    function test_ReleaseSubmitterBond_DisputedClaim_Reverts() public {
        bytes32 claimId = _submitPendAndChallenge();
        // Status is now Disputed and challenger != address(0)
        // Must pass Verified check first; here it fails on "claim not verified"
        vm.expectRevert("OracleRouter: claim not verified");
        oracleRouter.releaseSubmitterBond(claimId);
    }

    // ── InternalVote unit tests ───────────────────────────────────────────────

    function test_OpenVote_NotDisputed_Reverts() public {
        bytes32 claimId = _submitAndPend(); // Pending, not Disputed
        vm.expectRevert("InternalVote: claim not disputed");
        internalVote.openVote(claimId);
    }

    function test_OpenVote_AlreadyOpened_Reverts() public {
        bytes32 claimId = _submitPendAndChallenge();
        internalVote.openVote(claimId);
        vm.expectRevert("InternalVote: vote already opened");
        internalVote.openVote(claimId);
    }

    function test_CastVote_VoteNotOpened_Reverts() public {
        bytes32 claimId = _submitPendAndChallenge();
        vm.prank(voter1);
        vm.expectRevert("InternalVote: vote not opened");
        internalVote.castVote(claimId, true);
    }

    function test_CastVote_Unauthorized_Reverts() public {
        bytes32 claimId = _submitPendAndChallenge();
        internalVote.openVote(claimId);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        internalVote.castVote(claimId, true);
    }

    function test_CastVote_AlreadyVoted_Reverts() public {
        bytes32 claimId = _submitPendAndChallenge();
        internalVote.openVote(claimId);
        vm.prank(voter1);
        internalVote.castVote(claimId, true);
        vm.prank(voter1);
        vm.expectRevert("InternalVote: already voted");
        internalVote.castVote(claimId, true);
    }

    function test_FinalizeVote_QuorumNotReached_Reverts() public {
        bytes32 claimId = _submitPendAndChallenge();
        internalVote.openVote(claimId);
        vm.prank(voter1);
        internalVote.castVote(claimId, true); // weight = 1, quorum = 2
        vm.expectRevert("InternalVote: quorum not reached");
        internalVote.finalizeVote(claimId);
    }

    function test_FinalizeVote_NotOpened_Reverts() public {
        bytes32 claimId = _submitPendAndChallenge();
        vm.expectRevert("InternalVote: vote not opened");
        internalVote.finalizeVote(claimId);
    }

    function test_FinalizeVote_AlreadyFinalized_Reverts() public {
        bytes32 claimId = _submitPendAndChallenge();
        _openVoteAndCastTwo(claimId, true, true);
        internalVote.finalizeVote(claimId);
        vm.expectRevert("InternalVote: already finalized");
        internalVote.finalizeVote(claimId);
    }

    function test_WeightedVote_HigherWeightWins() public {
        // voter1 has weight=3, voter2 has weight=1; voter1 votes against → rejected despite 1 for
        vm.prank(admin);
        internalVote.setVoterWeight(voter1, 3);
        // quorumWeight=2 already satisfied by voter1 alone (weight=3)

        bytes32 claimId = _submitPendAndChallenge();
        internalVote.openVote(claimId);

        vm.prank(voter1);
        internalVote.castVote(claimId, false); // weight 3 against
        vm.prank(voter2);
        internalVote.castVote(claimId, true);  // weight 1 for → total 4, 1 for, 3 against

        internalVote.finalizeVote(claimId);

        ClaimRegistry.Claim memory c = registry.getClaim(claimId);
        assertEq(uint8(c.status), uint8(ClaimRegistry.Status.Rejected));
    }

    // ── Governance ────────────────────────────────────────────────────────────

    function test_SetVoterPool_Admin() public {
        address newPool = address(0xBEEF);
        vm.prank(admin);
        oracleRouter.setVoterPool(newPool);
        assertEq(oracleRouter.voterPool(), newPool);
    }

    function test_SetVoterPool_ZeroAddress_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("OracleRouter: zero address");
        oracleRouter.setVoterPool(address(0));
    }

    function test_SetQuorumWeight_Admin() public {
        vm.prank(admin);
        internalVote.setQuorumWeight(5);
        assertEq(internalVote.quorumWeight(), 5);
    }

    function test_SetQuorumWeight_Zero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("InternalVote: zero quorum");
        internalVote.setQuorumWeight(0);
    }
}
