# Deployment Guide

Plot Protocol deploys to Base Sepolia (testnet) and Base Mainnet via automated phase scripts.

## Automated Deployment (Recommended)

All deployment phases are orchestrated by scripts in `scripts/deploy/`. Each phase
validates its preconditions before acting, and every phase defaults to **dry-run** (simulation)
unless `--broadcast` is passed.

### Phase Overview

| Phase | Script | What it does |
|-------|--------|--------------|
| 1 | `phase1-prereqs.sh` | Validate tooling, .env, deployer balance, and test suite |
| 2 | `phase2-deploy-contracts.sh` | Deploy all 13 contracts via `forge script` |
| 3 | `phase3-wire-roles.sh` | Grant all AccessControl roles + verify on-chain |
| –  | `smoke-test.sh` | Read-only invariant checks (run after phase 3) |
| 4 | `phase4-services.sh` | Inject addresses into .env and start PM2 services |
| 5 | `phase5-mainnet.sh` | Mainnet safety wrapper: runs phases 2–4 with pre-flight gates |

### Quick Reference

```bash
# Testnet (Base Sepolia)
bash scripts/deploy/phase1-prereqs.sh
bash scripts/deploy/phase2-deploy-contracts.sh --network base_sepolia --broadcast
bash scripts/deploy/phase3-wire-roles.sh       --network base_sepolia --broadcast
bash scripts/deploy/smoke-test.sh              --network base_sepolia
bash scripts/deploy/phase4-services.sh         --network base_sepolia

# Mainnet (runs all phases internally with 7-point pre-flight check)
bash scripts/deploy/phase5-mainnet.sh --confirm-mainnet
# With hardware wallet:
bash scripts/deploy/phase5-mainnet.sh --confirm-mainnet --ledger
```

### Keeper Scripts

Ongoing keeper automation (run post-deployment):

```bash
# Daily price snapshot (cron: 0 0 * * *)
bash scripts/keepers/record-snapshots.sh --network base_mainnet --interval 24h

# Weekly price snapshot (cron: 0 0 * * 0)
bash scripts/keepers/record-snapshots.sh --network base_mainnet --interval 7d

# Claim finalization every 5 min (cron: */5 * * * *)
bash scripts/keepers/finalize-claims.sh  --network base_mainnet
```

---

## Detailed Guides

1. [Prerequisites](01-prerequisites.md) — tooling, environment variables, accounts
2. [Deploy to Base Sepolia](02-deploy-base-sepolia.md) — testnet step-by-step
3. [Deploy to Base Mainnet](03-deploy-base-mainnet.md) — mainnet with safety checklist
4. [Post-Deployment Setup](04-post-deploy-setup.md) — keepers, PM2, Qdrant
5. [Manual Deployment Reference](05-manual-reference.md) — raw forge commands without scripts

---

## Contract Deployment Order

```
Phase 1: Token Layer (no dependencies)
  1. PLOTToken(admin, treasury_wallet)
  2. BondCalculator(admin)

Phase 2: Escrow & Registry (depends on Phase 1)
  3. BondEscrow(usdc_address, treasury_wallet, admin)
  4. ClaimRegistry(admin, bondEscrow, bondCalculator)

Phase 3: Verification Pipeline (depends on Phase 2)
  5. NoveltyGate(admin, claimRegistry)
  6. ChallengeWindow(admin, claimRegistry, usdc_address, treasury_wallet)
  7. ConfidenceScorer(admin)

Phase 4: Resolution Layer (depends on Phase 2, Phase 3)
  8. OracleRouter(admin, claimRegistry, bondEscrow, challengeWindow, voterPool)
  9. InternalVote(admin, claimRegistry, oracleRouter, confidenceScorer, quorumWeight)

Phase 5: Governance & Economics (depends on Phase 1)
  10. EmissionController(admin, plotToken, chainlinkPriceFeed)
  11. TimelockController(timelockDelay, proposers=[], executors=[], admin)
  12. GovernorPlot(plotToken, timelock, votingDelay, votingPeriod, threshold, quorum)
  13. Treasury(admin, foundation_multisig, usdc_address)
```

---

## Key Addresses

### Base Mainnet
| Contract | Address |
|----------|---------|
| USDC (native) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Chainlink ETH/USD (placeholder) | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| Chainlink PLOT/USD | TBD — register after token deployment |

### Base Sepolia (testnet)
| Contract | Address |
|----------|---------|
| USDC (test) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Chain ID | 84532 |
| RPC | `https://sepolia.base.org` |
| Explorer | `https://sepolia.basescan.org` |
