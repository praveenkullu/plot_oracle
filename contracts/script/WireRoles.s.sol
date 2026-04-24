// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/ClaimRegistry.sol";
import "../src/BondEscrow.sol";
import "../src/ChallengeWindow.sol";
import "../src/OracleRouter.sol";
import "../src/NoveltyGate.sol";
import "../src/PLOTToken.sol";
import "../src/EmissionController.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract WireRoles is Script {
    // All addresses read from env — populated by phase3-wire-roles.sh after phase2 writes them
    address claimRegistry   = vm.envAddress("CLAIM_REGISTRY_ADDRESS");
    address bondEscrow      = vm.envAddress("BOND_ESCROW_ADDRESS");
    address challengeWindow = vm.envAddress("CHALLENGE_WINDOW_ADDRESS");
    address oracleRouter    = vm.envAddress("ORACLE_ROUTER_ADDRESS");
    address internalVote    = vm.envAddress("INTERNAL_VOTE_ADDRESS");
    address noveltyGate     = vm.envAddress("NOVELTY_GATE_ADDRESS");
    address plotToken       = vm.envAddress("PLOT_TOKEN_ADDRESS");
    address emissionCtrl    = vm.envAddress("EMISSION_CONTROLLER_ADDRESS");
    address timelock        = vm.envAddress("TIMELOCK_ADDRESS");
    address governor        = vm.envAddress("GOVERNOR_ADDRESS");
    address snsOracleWallet = vm.envAddress("SNS_ORACLE_WALLET");
    address operatorWallet  = vm.envAddress("OPERATOR_WALLET");

    function run() external {
        vm.startBroadcast();

        // ClaimRegistry: grant NoveltyGate and OracleRouter their caller roles
        ClaimRegistry cr = ClaimRegistry(claimRegistry);
        cr.grantRole(cr.NOVELTY_GATE_ROLE(),  noveltyGate);
        cr.grantRole(cr.ORACLE_ROUTER_ROLE(), oracleRouter);

        // BondEscrow: ClaimRegistry opens bonds, OracleRouter settles them
        BondEscrow be = BondEscrow(bondEscrow);
        be.grantRole(be.CLAIM_REGISTRY_ROLE(), claimRegistry);
        be.grantRole(be.ORACLE_ROUTER_ROLE(),  oracleRouter);

        // ChallengeWindow: OracleRouter reads window state and closes disputes
        ChallengeWindow cw = ChallengeWindow(challengeWindow);
        cw.grantRole(cw.ORACLE_ROUTER_ROLE(), oracleRouter);

        // OracleRouter: InternalVote pushes verdicts back
        OracleRouter or_ = OracleRouter(oracleRouter);
        or_.grantRole(or_.INTERNAL_VOTE_ROLE(), internalVote);

        // NoveltyGate: off-chain SNS service submits novelty results
        bytes32 SNS_ORACLE_ROLE = keccak256("SNS_ORACLE_ROLE");
        NoveltyGate(noveltyGate).grantRole(SNS_ORACLE_ROLE, snsOracleWallet);

        // PLOTToken: EmissionController is the only minter
        PLOTToken pt = PLOTToken(plotToken);
        pt.grantRole(pt.MINTER_ROLE(), emissionCtrl);

        // EmissionController: operator/keeper wallet for snapshots and mint
        bytes32 OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
        EmissionController(emissionCtrl).grantRole(OPERATOR_ROLE, operatorWallet);

        // TimelockController: Governor is proposer, executor, and canceller
        TimelockController tc = TimelockController(payable(timelock));
        tc.grantRole(tc.PROPOSER_ROLE(),  governor);
        tc.grantRole(tc.EXECUTOR_ROLE(),  governor);
        tc.grantRole(tc.CANCELLER_ROLE(), governor);

        vm.stopBroadcast();

        console.log("All roles wired successfully");
    }
}
