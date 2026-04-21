# Deployment Guide

This guide covers deploying Plot Protocol contracts to Base Sepolia (testnet) and Base Mainnet.

## Prerequisites

Before deploying, read:
1. [Prerequisites](01-prerequisites.md) — tooling, environment variables, accounts
2. [Deploy to Base Sepolia](02-deploy-base-sepolia.md) — testnet deployment
3. [Deploy to Base Mainnet](03-deploy-base-mainnet.md) — mainnet deployment with safety checklist
4. [Post-Deployment Setup](04-post-deploy-setup.md) — role wiring, keepers, PM2

## Deployment Order

Contracts must be deployed in dependency order:

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

## Key Addresses

### Base Mainnet
| Contract | Address |
|----------|---------|
| USDC (native) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| EAS | `0x4200000000000000000000000000000000000021` |
| Schema Registry | `0x4200000000000000000000000000000000000020` |
| Chainlink PLOT/USD | TBD — register after token deployment |

### Base Sepolia (testnet)
| Contract | Address |
|----------|---------|
| USDC | Deploy mock or use `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Chain ID | 84532 |
| RPC | `https://sepolia.base.org` |
| Explorer | `https://sepolia.basescan.org` |
