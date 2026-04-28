# Plot Protocol — Documentation Index

Plot Protocol is a blockchain-based truth verification system deployed on Base L2 (Chain ID 8453).
It uses economic incentives (bonds), distributed voting, and semantic novelty detection to create
a tamper-proof archive of verified claims.

---

## Quick Start for New Readers

Read in this order:
1. **[Architecture Overview](#architecture-overview)** below — understand the big picture
2. **[Module 1: Core Data Model](modules/01-core-data-model.md)** — the foundation every other module builds on
3. (disabled)**[Module 2: Novelty Detection](modules/02-novelty-detection.md)** — how duplicate/similar claims are filtered
4. **[Module 3: Challenge Window](modules/03-challenge-window.md)** — the optimistic challenge mechanism
5. **[Module 4: Oracle Router & Voting](modules/04-oracle-router.md)** — dispute resolution and voting
6. **[Module 5: Confidence Scoring](modules/05-confidence-scoring.md)** — how trust scores are computed
7. **[Module 6: Token Economics](modules/06-token-economics.md)** — PLOT token, governance, treasury

Then read:
- **[Deployment Guide](deployment/README.md)** — how to deploy to Base Sepolia / Mainnet
- **[Off-Chain Services](services/README.md)** — Node.js API, Ponder indexer

---

## Architecture Overview

### What Problem Does This Solve?

The internet is full of unverified claims. Plot Protocol creates an economic mechanism where:
- **Submitters** put money at risk when they submit a claim (bond = skin in the game)
- **Challengers** can dispute false claims and earn a reward if they're right
- **Voters** (PLOT token holders) adjudicate disputes and earn fees for correct votes
- The result is a permanently archived, confidence-scored, tamper-proof claim record on Arweave

### Two-Layer Architecture

```
Layer 1: On-Chain (Base L2)
  — Claim IDs, hashes, status, bonds, votes, scores stored here
  — Smart contracts enforce rules; nothing can be altered retroactively

Layer 2: Off-Chain
  — Full claim text, evidence, rationales stored on Arweave (permanent)
  — Event indexing (Ponder) and API (Node.js)
```

### The Claim Lifecycle

```
Submitter posts claim
       │
       ▼
[ClaimRegistry] submitClaim()
  ├── Bond locked in BondEscrow (USDC)
  ├── Status: Submitted
  └── contentHash deduplicated (Layer 1 novelty — reverts on exact duplicate)
       │
       ▼
[NoveltyGate] submitNoveltyResult()  [passthrough — always novel]
  └── Status: Pending
       │
       ▼
[ChallengeWindow] openWindow()
  ├── 2-hour window for anyone to dispute
  ├── No challenger → finalizeUnchallenged() → Status: Verified (score=100)
  └── Challenger posts counter-bond → Status: Disputed
       │ (disputed)
       ▼
[InternalVote] openVote() → castVote() → finalizeVote()
  │
  └── [OracleRouter] executeResolution()
        ├── Submitter wins → Status: Verified, bond returned, challenger slashed
        └── Submitter loses → Status: Rejected, bond slashed (60% challenger, 20% voters, 20% treasury)
```

### Smart Contract Dependency Map

```
PLOTToken ◄──────────────────── EmissionController (mints)
    │
    └── ERC20Votes ◄─────────── GovernorPlot (votes with PLOT)
                                    │
                                    └── TimelockController ◄── Treasury (executor)

BondCalculator ◄──── ClaimRegistry (calculates bond required)
BondEscrow     ◄──── ClaimRegistry (locks bond on submit)
                ◄──── OracleRouter  (releases/slashes on resolve)

ClaimRegistry  ◄──── NoveltyGate   (records novelty result)
               ◄──── ChallengeWindow (marks disputed / resolves unchallenged)
               ◄──── OracleRouter   (resolves verified/rejected, finalizes domain)

ChallengeWindow ◄─── OracleRouter  (releases/slashes challenger bond)

ConfidenceScorer ◄── InternalVote  (computes final score)

OracleRouter ◄────── InternalVote  (executes resolution)
```

### Role Map

| Role | Held By | Grants Access To |
|------|---------|-----------------|
| `DEFAULT_ADMIN_ROLE` | Deployer / multisig | All admin functions across all contracts |
| `MINTER_ROLE` | EmissionController | `PLOTToken.mint()` |
| `SLASHER_ROLE` | BondEscrow, InternalVote | `PLOTToken.slash()` |
| `ORACLE_ROUTER_ROLE` | OracleRouter | ClaimRegistry resolve/finalize, BondEscrow release/slash, ChallengeWindow bond ops |
| `NOVELTY_GATE_ROLE` | NoveltyGate | `ClaimRegistry.recordNoveltyResult()` |
| `INTERNAL_VOTE_ROLE` | InternalVote | `OracleRouter.executeResolution()` |
| `CLAIM_REGISTRY_ROLE` | ClaimRegistry | `BondEscrow.lockBond()` |
| `GOVERNANCE_ROLE` | GovernorPlot (via timelock) | `BondCalculator.setDomainBaseBond()` |
| `SNS_ORACLE_ROLE` | SNS service wallet | `NoveltyGate.submitNoveltyResult()` |
| `OPERATOR_ROLE` | Keeper / automation | `EmissionController.mintEmission()`, snapshots |
| `EXECUTOR_ROLE` | TimelockController | `Treasury.withdraw()`, `Treasury.initiateBuyback()` |
| `FOUNDATION_ROLE` | Foundation multisig | `Treasury.veto()` (expires 2 years post-deploy) |
| `VOTER_ROLE` | Registered voters | `InternalVote.castVote()` |

---

## Repository Structure

```
plot_oracle/
├── contracts/                  # Solidity contracts (Foundry)
│   ├── src/                    # All 13 production contracts
│   ├── test/                   # Foundry test files (138 tests)
│   ├── script/                 # Foundry deployment scripts (Deploy, WireRoles, SetTestnetBonds)
│   ├── lib/                    # OpenZeppelin + Chainlink
│   └── foundry.toml            # Forge config, RPC endpoints, Etherscan keys
├── backend/                    # Node.js / Express REST API (TypeScript)
│   ├── src/
│   │   ├── index.ts            # Express app + /health
│   │   ├── lib/
│   │   │   ├── env.ts          # Typed env vars
│   │   │   ├── contracts.ts    # ethers provider + contract instances
│   │   │   └── sns.ts          # SNS HTTP client
│   │   └── routes/
│   │       └── claims.ts       # POST/GET /claims handlers
│   └── package.json
├── services/
│   └── sns/                    # Python FastAPI — Semantic Novelty Service
│       ├── app/
│       │   ├── main.py         # FastAPI app entry point
│       │   ├── config.py       # Settings (model name, thresholds, Qdrant config)
│       │   ├── models.py       # Pydantic request/response schemas
│       │   ├── embeddings.py   # Abstract + Qdrant embedding service
│       │   └── routers/
│       │       └── novelty.py  # /novelty/check and /novelty/embed endpoints
│       └── tests/              # Pytest suite
├── indexer/                    # Ponder event indexer (TypeScript)
│   ├── ponder.config.ts        # Network, contract addresses, ABIs
│   ├── ponder.schema.ts        # onchainTable schema (Drizzle ORM)
│   └── src/index.ts            # Event handlers
├── scripts/
│   ├── deploy/                 # Phase 1–5 deployment automation (bash)
│   │   ├── phase1-prereqs.sh
│   │   ├── phase2-deploy-contracts.sh
│   │   ├── phase3-wire-roles.sh
│   │   ├── phase4-services.sh
│   │   ├── phase5-mainnet.sh
│   │   └── smoke-test.sh
│   ├── keepers/                # Keeper automation (bash)
│   │   ├── finalize-claims.sh  # finalizeUnchallenged + releaseSubmitterBond
│   │   ├── record-snapshots.sh # EmissionController price snapshots
│   │   └── run-keeper-loop.sh  # Testnet demo polling loop
│   └── test/
│       └── e2e-claim.sh        # Full end-to-end claim pipeline test
├── deployments/
│   └── base_sepolia.json       # Deployed contract addresses (auto-written by phase2)
├── ecosystem.config.cjs        # PM2 process manager config (all 3 services)
├── IMPLEMENTATION_PLAN.md      # Original design spec
└── docs/                       # This documentation
    ├── README.md               # This file
    ├── modules/                # Per-module deep dives
    ├── services/               # Off-chain service docs (API, SNS, Indexer, Keepers)
    └── deployment/             # Deployment guides (phases 1–5 + manual reference)
```
