# Ponder Indexer

**Port:** 42069
**Technology:** [Ponder.sh](https://ponder.sh) — Base-native event indexer
**PM2 name:** `plot-oracle-42069`

**Status: Architecture defined; implementation pending**

---

## What It Does

Ponder listens to Base L2 and indexes Plot Protocol contract events into a local database.
The Node.js API queries Ponder instead of reading from the chain directly — this is much faster
and cheaper than calling `eth_call` for every query.

---

## Events to Index

### ClaimRegistry events

| Event | Fields | Use Case |
|-------|--------|----------|
| `ClaimSubmitted` | claimId, submitter, contentHash, domain, bond | List claims, submitter history |
| `StatusChanged` | claimId, oldStatus, newStatus | Status timeline |
| `DomainFinalized` | claimId, voterAssignedDomain | Final domain tag |
| `NoveltyResult` | claimId, passed | Novelty outcome |
| `ConfidenceScoreSet` | claimId, score | Final confidence score |
| `ClaimSuperseded` | oldClaimId, newClaimId | Version history |

### ChallengeWindow events

| Event | Fields | Use Case |
|-------|--------|----------|
| `WindowOpened` | claimId, expiresAt | Display countdown |
| `ChallengeOpened` | claimId, challenger, bond | Show who challenged |
| `WindowExpired` | claimId | Mark unchallenged finalization |

### OracleRouter events

| Event | Fields | Use Case |
|-------|--------|----------|
| `DisputeResolved` | claimId, verified, score | Final resolution record |
| `SubmitterBondReleased` | claimId | Bond return confirmation |

### InternalVote events

| Event | Fields | Use Case |
|-------|--------|----------|
| `VoteOpened` | claimId | Show vote is active |
| `VoteCast` | claimId, voter, support, weight | Vote tally display |
| `VoteFinalized` | claimId, verified, weightFor, weightAgainst | Outcome with breakdown |

### EmissionController events

| Event | Fields | Use Case |
|-------|--------|----------|
| `EmissionMinted` | to, amount | Emission history |
| `CircuitBreakerTriggered` | pausedUntil | Show pause status |
| `EmergencyModeActivated` | — | Alert dashboard |

---

## Ponder Configuration (ponder.config.ts)

```typescript
import { createConfig } from "@ponder/core";
import { http } from "viem";

import ClaimRegistryAbi from "../contracts/out/ClaimRegistry.sol/ClaimRegistry.json";
import ChallengeWindowAbi from "../contracts/out/ChallengeWindow.sol/ChallengeWindow.json";
import OracleRouterAbi from "../contracts/out/OracleRouter.sol/OracleRouter.json";
import InternalVoteAbi from "../contracts/out/InternalVote.sol/InternalVote.json";
import EmissionControllerAbi from "../contracts/out/EmissionController.sol/EmissionController.json";

export default createConfig({
  networks: {
    base: {
      chainId: 8453,
      transport: http(process.env.BASE_RPC_URL),
    },
  },
  contracts: {
    ClaimRegistry: {
      network: "base",
      abi: ClaimRegistryAbi.abi,
      address: process.env.CLAIM_REGISTRY_ADDRESS as `0x${string}`,
      startBlock: parseInt(process.env.DEPLOY_BLOCK ?? "0"),
    },
    ChallengeWindow: {
      network: "base",
      abi: ChallengeWindowAbi.abi,
      address: process.env.CHALLENGE_WINDOW_ADDRESS as `0x${string}`,
      startBlock: parseInt(process.env.DEPLOY_BLOCK ?? "0"),
    },
    OracleRouter: {
      network: "base",
      abi: OracleRouterAbi.abi,
      address: process.env.ORACLE_ROUTER_ADDRESS as `0x${string}`,
      startBlock: parseInt(process.env.DEPLOY_BLOCK ?? "0"),
    },
    InternalVote: {
      network: "base",
      abi: InternalVoteAbi.abi,
      address: process.env.INTERNAL_VOTE_ADDRESS as `0x${string}`,
      startBlock: parseInt(process.env.DEPLOY_BLOCK ?? "0"),
    },
    EmissionController: {
      network: "base",
      abi: EmissionControllerAbi.abi,
      address: process.env.EMISSION_CONTROLLER_ADDRESS as `0x${string}`,
      startBlock: parseInt(process.env.DEPLOY_BLOCK ?? "0"),
    },
  },
});
```

---

## Schema (ponder.schema.ts)

```typescript
import { createSchema } from "@ponder/core";

export default createSchema((p) => ({
  Claim: p.createTable({
    id: p.string(),               // bytes32 claimId as hex string
    contentHash: p.string(),
    submitter: p.string(),
    bond: p.bigint(),
    status: p.string(),           // Submitted | Pending | Disputed | Verified | Rejected | Superseded
    selfDeclaredDomain: p.int(),
    voterAssignedDomain: p.int().optional(),
    domainFinalized: p.boolean(),
    confidenceScore: p.int().optional(),
    submittedAt: p.bigint(),
    previousVersion: p.string().optional(),
    nextVersion: p.string().optional(),
    noveltyPassed: p.boolean().optional(),
    arweaveTxId: p.string().optional(),
  }),

  ChallengeWindow: p.createTable({
    id: p.string(),               // claimId
    openedAt: p.bigint(),
    expiresAt: p.bigint(),
    challenger: p.string().optional(),
    challengerBond: p.bigint(),
    finalized: p.boolean(),
  }),

  VoteRecord: p.createTable({
    id: p.string(),               // claimId
    openedAt: p.bigint(),
    weightFor: p.bigint(),
    weightAgainst: p.bigint(),
    finalized: p.boolean(),
    verified: p.boolean().optional(),
  }),

  Emission: p.createTable({
    id: p.string(),               // tx hash
    to: p.string(),
    amount: p.bigint(),
    timestamp: p.bigint(),
  }),
}));
```

---

## Event Handlers (src/index.ts)

```typescript
import { ponder } from "@/generated";

ponder.on("ClaimRegistry:ClaimSubmitted", async ({ event, context }) => {
  const { ClaimRegistry } = context.db;
  await ClaimRegistry.create({
    id: event.args.claimId,
    data: {
      contentHash: event.args.contentHash,
      submitter: event.args.submitter,
      bond: event.args.bond,
      status: "Submitted",
      selfDeclaredDomain: event.args.selfDeclaredDomain,
      domainFinalized: false,
      submittedAt: event.block.timestamp,
      noveltyPassed: false,
    },
  });
});

ponder.on("ClaimRegistry:StatusChanged", async ({ event, context }) => {
  const { ClaimRegistry } = context.db;
  const statusNames = ["Submitted", "Pending", "Disputed", "Verified", "Rejected", "Superseded"];
  await ClaimRegistry.update({
    id: event.args.claimId,
    data: { status: statusNames[event.args.newStatus] },
  });
});

ponder.on("ClaimRegistry:ConfidenceScoreSet", async ({ event, context }) => {
  const { ClaimRegistry } = context.db;
  await ClaimRegistry.update({
    id: event.args.claimId,
    data: { confidenceScore: event.args.score },
  });
});

// ... similar handlers for other events
```

---

## GraphQL API (auto-generated by Ponder)

Ponder automatically generates a GraphQL API at `http://localhost:42069/graphql`.

Example query:
```graphql
{
  claims(
    where: { status: "Pending", selfDeclaredDomain: 2 }
    orderBy: "submittedAt"
    orderDirection: "desc"
    limit: 10
  ) {
    items {
      id
      submitter
      bond
      status
      confidenceScore
      submittedAt
    }
  }
}
```

---

## Implementation Plan

1. Create `services/indexer/` directory with `package.json`
2. Install Ponder: `bun add @ponder/core viem`
3. Copy contract ABIs from `contracts/out/`
4. Write `ponder.config.ts` with contract addresses from `.env`
5. Write `ponder.schema.ts` with all tables
6. Write event handlers in `src/index.ts`
7. Run `bun ponder dev` to start local development
8. Query at `http://localhost:42069/graphql`
9. Add to `ecosystem.config.cjs` for PM2 management

---

## Environment Variables

```env
BASE_RPC_URL=https://mainnet.base.org
DEPLOY_BLOCK=<block number when contracts were deployed>
CLAIM_REGISTRY_ADDRESS=0x...
CHALLENGE_WINDOW_ADDRESS=0x...
ORACLE_ROUTER_ADDRESS=0x...
INTERNAL_VOTE_ADDRESS=0x...
EMISSION_CONTROLLER_ADDRESS=0x...
```
