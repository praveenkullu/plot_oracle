// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/PLOTToken.sol";
import "../src/BondCalculator.sol";
import "../src/BondEscrow.sol";
import "../src/ClaimRegistry.sol";
import "../src/NoveltyGate.sol";
import "../src/ChallengeWindow.sol";
import "../src/ConfidenceScorer.sol";
import "../src/OracleRouter.sol";
import "../src/InternalVote.sol";
import "../src/EmissionController.sol";
import "../src/GovernorPlot.sol";
import "../src/Treasury.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract Deploy is Script {
    // ── Required inputs ────────────────────────────────────────────────────────
    address admin      = vm.envAddress("ADMIN_ADDRESS");
    address foundation = vm.envAddress("FOUNDATION_ADDRESS");
    address treasuryW  = vm.envAddress("TREASURY_WALLET");
    address voterPool  = vm.envAddress("VOTER_POOL_ADDRESS");
    address priceFeed  = vm.envAddress("CHAINLINK_PLOT_USD_FEED");

    // ── USDC address — override via env for forks/testnets ────────────────────
    // Base Sepolia test USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
    // Base Mainnet USDC:      0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    address usdc = vm.envOr("USDC_ADDRESS", address(0x036CbD53842c5426634e7929541eC2318f3dCF7e));

    // ── Governor parameters — read from env, fall back to testnet defaults ─────
    // Mainnet values (set in .env before running phase5-mainnet.sh):
    //   GOVERNOR_VOTING_DELAY=172800     (~2 days at 1s/block)
    //   GOVERNOR_VOTING_PERIOD=1209600   (~14 days)
    //   GOVERNOR_PROP_THRESHOLD=10000    (in PLOT, without decimals — script adds 1e18)
    //   GOVERNOR_QUORUM_NUM=4            (4%)
    //   TIMELOCK_DELAY=172800            (2 days in seconds)
    uint48  votingDelay   = uint48(vm.envOr("GOVERNOR_VOTING_DELAY",   uint256(86400)));  // ~1 day testnet
    uint32  votingPeriod  = uint32(vm.envOr("GOVERNOR_VOTING_PERIOD",  uint256(604800))); // ~7 days testnet
    uint256 propThreshold = vm.envOr("GOVERNOR_PROP_THRESHOLD", uint256(10_000)) * 1e18;
    uint256 quorumNum     = vm.envOr("GOVERNOR_QUORUM_NUM",     uint256(4));
    uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY",          uint256(172800));         // 2 days

    uint256 quorumWeight  = vm.envOr("INTERNAL_VOTE_QUORUM",    uint256(3));

    function run() external {
        vm.startBroadcast();

        // ── Phase 1: Token layer ──────────────────────────────────────────────
        PLOTToken      plot    = new PLOTToken(admin, treasuryW);
        BondCalculator calc    = new BondCalculator(admin);

        // ── Phase 2: Escrow & registry ────────────────────────────────────────
        BondEscrow    escrow   = new BondEscrow(usdc, treasuryW, admin);
        ClaimRegistry registry = new ClaimRegistry(admin, address(escrow), address(calc));

        // ── Phase 3: Verification pipeline ───────────────────────────────────
        NoveltyGate     novelty = new NoveltyGate(admin, address(registry));
        ChallengeWindow window  = new ChallengeWindow(admin, address(registry), usdc, treasuryW);
        ConfidenceScorer scorer = new ConfidenceScorer(admin);

        // ── Phase 4: Resolution ───────────────────────────────────────────────
        OracleRouter router = new OracleRouter(
            admin, address(registry), address(escrow), address(window), voterPool
        );
        InternalVote vote = new InternalVote(
            admin, address(registry), address(router), address(scorer), quorumWeight
        );

        // ── Phase 5: Governance & economics ──────────────────────────────────
        EmissionController emCtrl = new EmissionController(admin, address(plot), priceFeed);

        address[] memory empty = new address[](0);
        TimelockController timelock = new TimelockController(timelockDelay, empty, empty, admin);

        GovernorPlot governor = new GovernorPlot(
            IVotes(address(plot)), timelock,
            votingDelay, votingPeriod, propThreshold, quorumNum
        );

        Treasury tsy = new Treasury(admin, foundation, usdc);

        vm.stopBroadcast();

        // ── Log all deployed addresses ────────────────────────────────────────
        console.log("=== Plot Protocol Deployment ===");
        console.log("PLOTToken:          ", address(plot));
        console.log("BondCalculator:     ", address(calc));
        console.log("BondEscrow:         ", address(escrow));
        console.log("ClaimRegistry:      ", address(registry));
        console.log("NoveltyGate:        ", address(novelty));
        console.log("ChallengeWindow:    ", address(window));
        console.log("ConfidenceScorer:   ", address(scorer));
        console.log("OracleRouter:       ", address(router));
        console.log("InternalVote:       ", address(vote));
        console.log("EmissionController: ", address(emCtrl));
        console.log("TimelockController: ", address(timelock));
        console.log("GovernorPlot:       ", address(governor));
        console.log("Treasury:           ", address(tsy));
    }
}
