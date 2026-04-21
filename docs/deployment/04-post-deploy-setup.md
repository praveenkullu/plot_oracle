# Post-Deployment Setup

After contracts are deployed and roles are wired, set up the automated keepers and off-chain
services that keep the protocol running.

---

## Keeper Tasks Required

These operations cannot run autonomously — they require off-chain triggers:

| Task | Frequency | Who Calls | Function |
|------|-----------|-----------|----------|
| Record 24h price snapshot | Daily | Operator keeper | `EmissionController.recordSnapshot24h()` |
| Record 7d price snapshot | Weekly | Operator keeper | `EmissionController.recordSnapshot7d()` |
| Check circuit breaker | Hourly | Anyone (permissionless) | `EmissionController.checkCircuitBreaker()` |
| Mint PLOT emissions | Weekly or monthly | Operator keeper | `EmissionController.mintEmission(rewardsPool)` |
| Finalize unchallenged claims | Every few minutes | Anyone (permissionless) | `ChallengeWindow.finalizeUnchallenged(claimId)` |
| Release submitter bonds | After finalize | Anyone (permissionless) | `OracleRouter.releaseSubmitterBond(claimId)` |
| Open vote for disputed claims | After challenge | Anyone (permissionless) | `InternalVote.openVote(claimId)` |
| Finalize vote | After quorum | Anyone (permissionless) | `InternalVote.finalizeVote(claimId)` |
| Store claim embeddings | After verify | SNS oracle | `POST /novelty/embed` |

---

## Chainlink Automation (Recommended)

For production, use Chainlink Automation to trigger keeper functions automatically.

### Register upkeeps

1. Go to [automation.chain.link](https://automation.chain.link/) and connect to Base Mainnet
2. Register two upkeeps:

**Upkeep 1: Price Snapshots**
```
Target contract: EmissionController address
Selector: recordSnapshot24h() — trigger daily
Selector: recordSnapshot7d() — trigger weekly
LINK funding: ~10 LINK
```

**Upkeep 2: Circuit Breaker Monitor**
```
Target contract: EmissionController address
Selector: checkCircuitBreaker() — trigger hourly
LINK funding: ~50 LINK
```

### Custom logic upkeep (for claim finalization)

Create a keeper contract `contracts/script/ClaimKeeperUpkeep.sol`:
```solidity
contract ClaimKeeperUpkeep {
    // Reads Ponder indexer for pending claims with expired windows
    // Calls ChallengeWindow.finalizeUnchallenged() for each
    // Calls OracleRouter.releaseSubmitterBond() for each verified, unbonded claim
}
```

---

## PM2 Process Manager

All off-chain services run via PM2. The `ecosystem.config.cjs` defines all processes.

### Current ecosystem.config.cjs

Located at: `/home/praveen/LTU/MCS5993_DCB/dev/plot_oracle/ecosystem.config.cjs`

Services:
| Name | Port | Description |
|------|------|-------------|
| `plot-oracle-3000` | 3000 | Node.js/Express API — event indexing, REST endpoints |
| `plot-oracle-8000` | 8000 | Python FastAPI — SNS (Semantic Novelty Service) |
| `plot-oracle-42069` | 42069 | Ponder indexer — reads Base L2 events |

### Start all services

```bash
# First time (registers processes)
~/.local/bin/pm2 start ecosystem.config.cjs

# After first time
~/.local/bin/pm2 start all

# Save process list (survives reboot)
~/.local/bin/pm2 save

# Check status
~/.local/bin/pm2 status
~/.local/bin/pm2 logs
~/.local/bin/pm2 monit
```

### Start/stop individual services

```bash
~/.local/bin/pm2 start plot-oracle-8000
~/.local/bin/pm2 stop plot-oracle-8000
~/.local/bin/pm2 restart plot-oracle-8000
~/.local/bin/pm2 logs plot-oracle-8000
```

---

## Environment Variable Update

After deployment, update the `.env` with all deployed contract addresses:

```env
# Deployed contract addresses (fill after deployment)
PLOT_TOKEN_ADDRESS=0x...
BOND_CALCULATOR_ADDRESS=0x...
BOND_ESCROW_ADDRESS=0x...
CLAIM_REGISTRY_ADDRESS=0x...
NOVELTY_GATE_ADDRESS=0x...
CHALLENGE_WINDOW_ADDRESS=0x...
CONFIDENCE_SCORER_ADDRESS=0x...
ORACLE_ROUTER_ADDRESS=0x...
INTERNAL_VOTE_ADDRESS=0x...
EMISSION_CONTROLLER_ADDRESS=0x...
TIMELOCK_ADDRESS=0x...
GOVERNOR_ADDRESS=0x...
TREASURY_ADDRESS=0x...
```

Then restart all services:
```bash
~/.local/bin/pm2 restart all
```

---

## Health Check

Verify all services are running correctly after deployment:

```bash
# SNS service
curl http://localhost:8000/health
# Expected: {"status":"ok"}

# Node.js API
curl http://localhost:3000/health
# Expected: {"status":"ok","chain":"base-mainnet"}

# Ponder indexer
curl http://localhost:42069/status
# Expected: running, synced to latest block

# Test a novelty check
curl -X POST http://localhost:8000/novelty/check \
  -H "Content-Type: application/json" \
  -d '{"claim_id":"test","claim_text":"Russia invaded Ukraine in February 2022","domain":"Finance"}'
```

---

## Setting Up Qdrant (Production)

For production, run Qdrant as a persistent service (not in-memory):

```bash
# Using Docker
docker run -d \
  --name qdrant \
  -p 6333:6333 \
  -p 6334:6334 \
  -v qdrant_storage:/qdrant/storage \
  qdrant/qdrant

# Verify
curl http://localhost:6333/healthz
```

Set in `.env`:
```env
QDRANT_IN_MEMORY=false
QDRANT_HOST=localhost
QDRANT_PORT=6333
```

For high availability, deploy Qdrant cluster or use Qdrant Cloud.

---

## First Emission Mint

After deployment, the first emission can be minted immediately (block.timestamp > deployedAt, so
elapsed > 0). In practice, wait for the first batch of verified claims before minting:

```bash
CAST=~/.config/.foundry/bin/cast

# Check pending emission
$CAST call $EMISSION_CONTROLLER_ADDRESS "pendingEmission()(uint256)" --rpc-url base_mainnet

# Mint (operator wallet required)
$CAST send $EMISSION_CONTROLLER_ADDRESS \
  "mintEmission(address)" $REWARDS_POOL_ADDRESS \
  --private-key $OPERATOR_PRIVATE_KEY \
  --rpc-url base_mainnet
```
