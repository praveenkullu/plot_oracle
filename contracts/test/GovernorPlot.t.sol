// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "../src/GovernorPlot.sol";
import "../src/PLOTToken.sol";

contract MockGovernanceTarget {
    bool public executed;
    function execute() external { executed = true; }
}

contract GovernorPlotTest is Test {
    PLOTToken          plot;
    TimelockController timelock;
    GovernorPlot       governor;
    MockGovernanceTarget target;

    address admin      = address(0xA0);
    address foundation = address(0xA1);
    address treasury   = address(0xA2);
    address voter1     = address(0xA3);
    address voter2     = address(0xA4);

    // Governor params (fast for tests)
    uint48  constant VOTING_DELAY     = 0;   // 0 blocks
    uint32  constant VOTING_PERIOD    = 10;  // 10 blocks
    uint256 constant PROPOSAL_THRESH  = 0;
    uint256 constant QUORUM_NUMERATOR = 1;   // 1%
    uint256 constant TIMELOCK_DELAY   = 0;   // 0 seconds

    function setUp() public {
        vm.warp(1_700_000_000); // realistic timestamp; avoids DONE_TIMESTAMP=1 collision in TimelockController
        vm.roll(1);

        plot   = new PLOTToken(admin, treasury);
        target = new MockGovernanceTarget();

        // Deploy timelock with no initial proposers/executors; admin is the deployer
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, admin);

        governor = new GovernorPlot(
            IVotes(address(plot)),
            timelock,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESH,
            QUORUM_NUMERATOR
        );

        // Wire roles: governor can propose and execute via timelock
        vm.startPrank(admin);
        timelock.grantRole(timelock.PROPOSER_ROLE(),  address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(),  address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // Mint PLOT to voters (enough to exceed 1% quorum of total supply)
        // Total supply starts at MAX_SUPPLY/5 = 200M; 1% = 2M; give voters 50M each
        plot.mint(voter1, 50_000_000e18);
        plot.mint(voter2, 50_000_000e18);
        vm.stopPrank();

        // Delegates must self-delegate to activate vote weight
        vm.prank(voter1);
        plot.delegate(voter1);
        vm.prank(voter2);
        plot.delegate(voter2);

        vm.roll(block.number + 1); // checkpoint delegation in the past
    }

    // ── Constructor params ────────────────────────────────────────────────────

    function test_GovernorParams() public view {
        assertEq(governor.votingDelay(),      VOTING_DELAY);
        assertEq(governor.votingPeriod(),     VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESH);
        assertEq(governor.name(),             "GovernorPlot");
        assertEq(governor.SUPERMAJORITY_NUMERATOR(),   67);
        assertEq(governor.SUPERMAJORITY_DENOMINATOR(), 100);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _propose() internal returns (uint256 proposalId) {
        address[] memory targets   = new address[](1);
        uint256[] memory values    = new uint256[](1);
        bytes[]   memory calldatas = new bytes[](1);
        targets[0]   = address(target);
        calldatas[0] = abi.encodeCall(target.execute, ());

        vm.prank(voter1);
        proposalId = governor.propose(targets, values, calldatas, "Proposal: execute target");
    }

    function _proposeAndPass() internal returns (
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[]   memory calldatas
    ) {
        targets   = new address[](1);
        values    = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0]   = address(target);
        calldatas[0] = abi.encodeCall(target.execute, ());

        vm.prank(voter1);
        proposalId = governor.propose(targets, values, calldatas, "Proposal: execute target");

        vm.roll(block.number + 1); // past voting delay → Active

        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For

        vm.roll(block.number + VOTING_PERIOD); // past voting period
    }

    // ── Full proposal lifecycle ────────────────────────────────────────────────

    function test_FullProposalLifecycle_ExecutesTarget() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
            = _proposeAndPass();

        // Queue
        bytes32 descHash = keccak256(bytes("Proposal: execute target"));
        governor.queue(targets, values, calldatas, descHash);

        // Execute (timelock delay = 0)
        governor.execute(targets, values, calldatas, descHash);

        assertTrue(target.executed());
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    // ── Supermajority voting ──────────────────────────────────────────────────

    function test_Supermajority_67pct_Succeeds() public {
        // voter1: 50M for, voter2: ~23.88M against → 50/(50+23.88) ≈ 67.7% > 67%
        // Easier: voter1 for, no against → 100% for → succeeds
        uint256 proposalId = _propose();
        vm.roll(block.number + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For (100%)

        vm.roll(block.number + VOTING_PERIOD);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_Supermajority_Below67pct_Defeated() public {
        // voter1: 50M for, voter2: 50M against → exactly 50%/50% < 67% → Defeated
        uint256 proposalId = _propose();
        vm.roll(block.number + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For
        vm.prank(voter2);
        governor.castVote(proposalId, 0); // Against

        vm.roll(block.number + VOTING_PERIOD);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_AllAgainst_Defeated() public {
        uint256 proposalId = _propose();
        vm.roll(block.number + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 0); // Against
        vm.prank(voter2);
        governor.castVote(proposalId, 0); // Against

        vm.roll(block.number + VOTING_PERIOD);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_NoVotes_Defeated() public {
        uint256 proposalId = _propose();
        vm.roll(block.number + VOTING_PERIOD + 1);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ── Quorum ────────────────────────────────────────────────────────────────

    function test_QuorumSatisfied_WithEnoughVotes() public {
        // voter1 alone has 50M which is >> 1% of total supply (≥300M) = 3M
        uint256 proposalId = _propose();
        vm.roll(block.number + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + VOTING_PERIOD);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    // ── State transitions ────────────────────────────────────────────────────

    function test_ProposalState_Pending_ThenActive() public {
        uint256 proposalId = _propose();
        // With votingDelay=0, snapshot = proposalCreationBlock
        // After rolling 1 block, clock > snapshot → Active
        vm.roll(block.number + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));
    }

    function test_CastVote_AlreadyVoted_Reverts() public {
        uint256 proposalId = _propose();
        vm.roll(block.number + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        vm.prank(voter1);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test_CastVote_NoTokens_ZeroWeight() public {
        address noTokenVoter = address(0xDEAD);
        // Grant VOTER_ROLE equivalent: just try to vote with 0 PLOT
        // GovernorPlot doesn't restrict who votes, but weight = 0 doesn't affect outcome

        uint256 proposalId = _propose();
        vm.roll(block.number + 1);

        vm.prank(noTokenVoter);
        governor.castVote(proposalId, 1); // Cast succeeds but weight = 0

        vm.roll(block.number + VOTING_PERIOD);

        // No weight → quorum not reached → Defeated
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }
}
