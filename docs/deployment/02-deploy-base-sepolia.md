# Deploy to Base Sepolia (Testnet)

Base Sepolia is the testnet for Base. It uses the same tools and scripts as mainnet but with
test ETH (free from faucets) and no real funds at risk.

## Before You Start

1. Complete [Prerequisites](01-prerequisites.md)
2. Have testnet ETH in your deployer account
3. Set all required `.env` variables (use any test addresses for admin/foundation/treasury)
4. Run `~/.config/.foundry/bin/forge test` — all 138 must pass

---

## Step 1: Create the Deployment Script

Create `contracts/script/Deploy.s.sol`:

```solidity
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
    // Inputs (override via environment variables)
    address admin       = vm.envAddress("ADMIN_ADDRESS");
    address foundation  = vm.envAddress("FOUNDATION_ADDRESS");
    address treasury_w  = vm.envAddress("TREASURY_WALLET");
    address voterPool   = vm.envAddress("VOTER_POOL_ADDRESS");
    address priceFeed   = vm.envAddress("CHAINLINK_PLOT_USD_FEED");

    // Base Sepolia USDC (test token)
    address usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    // Governor params (use production values or fast-test values)
    uint48  votingDelay    = 2 days / 2;   // ~1 day in blocks at 2s/block
    uint32  votingPeriod   = 14 days / 2;  // ~7 days in blocks
    uint256 propThreshold  = 10_000e18;    // 10,000 PLOT
    uint256 quorumNum      = 4;            // 4%
    uint256 timelockDelay  = 2 days;

    function run() external {
        vm.startBroadcast();

        // ── Phase 1: Token Layer ───────────────────────────────────────────────
        PLOTToken       plot    = new PLOTToken(admin, treasury_w);
        BondCalculator  calc    = new BondCalculator(admin);

        // ── Phase 2: Escrow & Registry ────────────────────────────────────────
        BondEscrow      escrow  = new BondEscrow(usdc, treasury_w, admin);
        ClaimRegistry   registry = new ClaimRegistry(admin, address(escrow), address(calc));

        // ── Phase 3: Verification Pipeline ───────────────────────────────────
        NoveltyGate     novelty  = new NoveltyGate(admin, address(registry));
        ChallengeWindow window   = new ChallengeWindow(admin, address(registry), usdc, treasury_w);
        ConfidenceScorer scorer  = new ConfidenceScorer(admin);

        // ── Phase 4: Resolution ───────────────────────────────────────────────
        OracleRouter router = new OracleRouter(
            admin, address(registry), address(escrow), address(window), voterPool
        );
        InternalVote vote = new InternalVote(
            admin, address(registry), address(router), address(scorer), 3 // quorumWeight=3
        );

        // ── Phase 5: Governance & Economics ──────────────────────────────────
        EmissionController emCtrl = new EmissionController(admin, address(plot), priceFeed);

        address[] memory empty = new address[](0);
        TimelockController timelock = new TimelockController(timelockDelay, empty, empty, admin);

        GovernorPlot governor = new GovernorPlot(
            IVotes(address(plot)), timelock,
            votingDelay, votingPeriod, propThreshold, quorumNum
        );

        Treasury tsy = new Treasury(admin, foundation, usdc);

        // ── Role wiring (must be done by admin) ───────────────────────────────
        // NOTE: vm.broadcast() sends these as admin — admin must be the broadcaster
        // OR do role wiring in a separate script after deployment

        vm.stopBroadcast();

        // Log all deployed addresses
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
```

---

## Step 2: Dry Run (Simulation)

Always simulate first — no gas spent, no real transactions:

```bash
cd contracts

~/.config/.foundry/bin/forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --sender $ADMIN_ADDRESS \
  -vvvv
```

This shows exactly what transactions would be sent and simulates their execution.

---

## Step 3: Deploy

```bash
~/.config/.foundry/bin/forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

Flags:
- `--broadcast` — actually send transactions
- `--verify` — automatically verify source code on BaseScan
- `-vvvv` — verbose output with transaction hashes

Save the output addresses to `.env.sepolia` for the next step.

---

## Step 4: Role Wiring Script

Create `contracts/script/WireRoles.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/ClaimRegistry.sol";
import "../src/BondEscrow.sol";
import "../src/ChallengeWindow.sol";
import "../src/OracleRouter.sol";
import "../src/PLOTToken.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract WireRoles is Script {
    // Fill from deployment output
    address claimRegistry    = vm.envAddress("CLAIM_REGISTRY_ADDRESS");
    address bondEscrow       = vm.envAddress("BOND_ESCROW_ADDRESS");
    address challengeWindow  = vm.envAddress("CHALLENGE_WINDOW_ADDRESS");
    address oracleRouter     = vm.envAddress("ORACLE_ROUTER_ADDRESS");
    address internalVote     = vm.envAddress("INTERNAL_VOTE_ADDRESS");
    address noveltyGate      = vm.envAddress("NOVELTY_GATE_ADDRESS");
    address plotToken        = vm.envAddress("PLOT_TOKEN_ADDRESS");
    address emissionCtrl     = vm.envAddress("EMISSION_CONTROLLER_ADDRESS");
    address timelock         = vm.envAddress("TIMELOCK_ADDRESS");
    address governor         = vm.envAddress("GOVERNOR_ADDRESS");
    address snsOracleWallet  = vm.envAddress("SNS_ORACLE_WALLET");
    address operatorWallet   = vm.envAddress("OPERATOR_WALLET");

    function run() external {
        vm.startBroadcast();

        // ClaimRegistry: grant roles to NoveltyGate and OracleRouter
        ClaimRegistry cr = ClaimRegistry(claimRegistry);
        cr.grantRole(cr.NOVELTY_GATE_ROLE(),   noveltyGate);
        cr.grantRole(cr.ORACLE_ROUTER_ROLE(),  oracleRouter);

        // BondEscrow: grant CLAIM_REGISTRY_ROLE and ORACLE_ROUTER_ROLE
        BondEscrow be = BondEscrow(bondEscrow);
        be.grantRole(be.CLAIM_REGISTRY_ROLE(), claimRegistry);
        be.grantRole(be.ORACLE_ROUTER_ROLE(),  oracleRouter);

        // ChallengeWindow: grant ORACLE_ROUTER_ROLE
        ChallengeWindow cw = ChallengeWindow(challengeWindow);
        cw.grantRole(cw.ORACLE_ROUTER_ROLE(), oracleRouter);

        // OracleRouter: grant INTERNAL_VOTE_ROLE to InternalVote
        OracleRouter or_ = OracleRouter(oracleRouter);
        or_.grantRole(or_.INTERNAL_VOTE_ROLE(), internalVote);

        // NoveltyGate: grant SNS_ORACLE_ROLE to SNS service wallet
        bytes32 SNS_ORACLE_ROLE = keccak256("SNS_ORACLE_ROLE");
        NoveltyGate(noveltyGate).grantRole(SNS_ORACLE_ROLE, snsOracleWallet);

        // PLOTToken: grant MINTER_ROLE to EmissionController
        PLOTToken pt = PLOTToken(plotToken);
        pt.grantRole(pt.MINTER_ROLE(), emissionCtrl);

        // EmissionController: grant OPERATOR_ROLE to keeper wallet
        bytes32 OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
        EmissionController(emissionCtrl).grantRole(OPERATOR_ROLE, operatorWallet);

        // GovernorPlot / TimelockController: wire governor as proposer/executor
        TimelockController tc = TimelockController(payable(timelock));
        tc.grantRole(tc.PROPOSER_ROLE(),  governor);
        tc.grantRole(tc.EXECUTOR_ROLE(),  governor);
        tc.grantRole(tc.CANCELLER_ROLE(), governor);

        vm.stopBroadcast();

        console.log("All roles wired successfully");
    }
}
```

Run role wiring:
```bash
~/.config/.foundry/bin/forge script script/WireRoles.s.sol \
  --rpc-url base_sepolia \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvvv
```

---

## Step 5: Smoke Test

Verify the deployment by reading key state:

```bash
FORGE=~/.config/.foundry/bin/forge
CAST=~/.config/.foundry/bin/cast

# Check PLOTToken has correct max supply
$CAST call $PLOT_TOKEN_ADDRESS "MAX_SUPPLY()(uint256)" --rpc-url base_sepolia

# Check treasury received 200M PLOT
$CAST call $PLOT_TOKEN_ADDRESS "balanceOf(address)(uint256)" $TREASURY_WALLET --rpc-url base_sepolia

# Check EmissionController year 0 rate
$CAST call $EMISSION_CONTROLLER_ADDRESS "currentRateBps()(uint256)" --rpc-url base_sepolia
# Expected: 10000

# Check Treasury vetoExpiresAt (should be ~730 days from now)
$CAST call $TREASURY_ADDRESS "vetoExpiresAt()(uint256)" --rpc-url base_sepolia
```

---

## Step 6: Start Off-Chain Services

After contracts are deployed, start the off-chain services with updated addresses:

```bash
# Update ecosystem.config.cjs with deployed contract addresses
# Then start PM2
~/.local/bin/pm2 start ecosystem.config.cjs
~/.local/bin/pm2 status

# Verify SNS service is running
curl http://localhost:8000/health
```

See [Services Guide](../services/README.md) for full service setup.
