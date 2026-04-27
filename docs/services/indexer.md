# Ponder Indexer

**Port:** 42069
**Technology:** [Ponder](https://ponder.sh) 0.7.17 — Base-native event indexer
**PM2 name:** `plot-oracle-42069`

**Status: Implemented and running on Base Sepolia testnet**

---

## What It Does

Ponder listens to Base Sepolia and indexes Plot Protocol contract events into a local PGlite database.
The Node.js API queries Ponder instead of reading from the chain directly — this is much faster
and cheaper than calling `eth_call` for every list query.

- **Sync time on first run:** ~60–300s to catch up from `startBlock` to the current chain head
- **GraphQL endpoint:** `http://localhost:42069/graphql`
- **Health endpoint:** `http://localhost:42069/health`

---

## Indexed Contracts

<!-- AUTO-GENERATED from indexer/ponder.config.ts -->

| Contract | Address (Base Sepolia) | startBlock |
|----------|------------------------|------------|
| ClaimRegistry | 0x4018c2cdc76d2282caabc40ab4fa16f3cca9f866 | 40666128 |
| ChallengeWindow | 0x596639e733dd9263ccfbce38f857688b40bb4c87 | 40666128 |
| OracleRouter | 0x4e9932c37e43cfcb973e00fc621973660a530e57 | 40666128 |
| InternalVote | 0x2e62f06f3a1d7028cc5182790d235667fb45ca53 | 40666128 |
| EmissionController | 0xe187aceaf04b9c791f58ba1de3a4342a92e7482b | 40666128 |

Contract addresses default to the values above when the env vars are not set. Set `DEPLOY_BLOCK` in `.env` to override the start block.

ABIs are loaded at runtime from `../contracts/out/<Name>.sol/<Name>.json` (Foundry build output).

<!-- END AUTO-GENERATED -->

---

## Database Schema

<!-- AUTO-GENERATED from indexer/ponder.schema.ts -->

Uses Ponder 0.7 `onchainTable` API (Drizzle ORM column types).

### `claim`

| Column | Type | Notes |
|--------|------|-------|
| `id` | hex (PK) | bytes32 claimId |
| `contentHash` | hex | keccak256 of claim payload |
| `submitter` | hex | submitter wallet address |
| `bond` | bigint | USDC bond amount (6 decimals) |
| `status` | text | `Submitted \| Pending \| Disputed \| Verified \| Rejected \| Superseded` |
| `selfDeclaredDomain` | integer | Domain enum (0–5) |
| `voterAssignedDomain` | integer? | Set after vote finalization |
| `domainFinalized` | boolean | True after DomainFinalized event |
| `confidenceScore` | integer? | Set by ConfidenceScorer |
| `submittedAt` | bigint | Block timestamp |
| `previousVersion` | hex? | Prior claim ID if this is a superseding claim |
| `nextVersion` | hex? | Superseding claim ID if this was superseded |
| `noveltyPassed` | boolean? | Result of SNS novelty check |

### `challenge_window`

| Column | Type | Notes |
|--------|------|-------|
| `id` | hex (PK) | claimId |
| `openedAt` | bigint | Block timestamp |
| `expiresAt` | bigint | Block timestamp |
| `challenger` | hex? | Challenger address if challenged |
| `challengerBond` | bigint? | USDC bond posted by challenger |
| `finalized` | boolean | True after WindowExpired event |

### `vote_record`

| Column | Type | Notes |
|--------|------|-------|
| `id` | hex (PK) | claimId |
| `openedAt` | bigint | Block timestamp |
| `weightFor` | bigint | Cumulative vote weight in favour |
| `weightAgainst` | bigint | Cumulative vote weight against |
| `finalized` | boolean | True after VoteFinalized event |
| `verified` | boolean? | Final vote outcome |

### `emission`

| Column | Type | Notes |
|--------|------|-------|
| `id` | text (PK) | `${txHash}-${logIndex}` |
| `to` | hex | Recipient address |
| `amount` | bigint | PLOT tokens minted |
| `timestamp` | bigint | Block timestamp |

<!-- END AUTO-GENERATED -->

---

## Events Indexed

<!-- AUTO-GENERATED from indexer/src/index.ts -->

### ClaimRegistry

| Event | Action |
|-------|--------|
| `ClaimSubmitted` | Insert `claim` row with status `Submitted` |
| `StatusChanged` | Update `claim.status` |
| `NoveltyResult` | Update `claim.noveltyPassed` |
| `ConfidenceScoreSet` | Update `claim.confidenceScore` |
| `DomainFinalized` | Update `claim.voterAssignedDomain` + `claim.domainFinalized = true` |
| `ClaimSuperseded` | Set `claim.nextVersion` on old row, `claim.previousVersion` on new row |

### ChallengeWindow

| Event | Action |
|-------|--------|
| `WindowOpened` | Insert `challenge_window` row |
| `ChallengeOpened` | Update `challenger` + `challengerBond` |
| `WindowExpired` | Update `finalized = true` |

### OracleRouter

| Event | Action |
|-------|--------|
| `DisputeResolved` | Update `claim.status` (`Verified` or `Rejected`) + `claim.confidenceScore` |

### InternalVote

| Event | Action |
|-------|--------|
| `VoteOpened` | Insert `vote_record` row |
| `VoteCast` | Accumulate `weightFor` or `weightAgainst` |
| `VoteFinalized` | Update final weights + `finalized = true` + `verified` |

### EmissionController

| Event | Action |
|-------|--------|
| `EmissionMinted` | Insert `emission` row |

<!-- END AUTO-GENERATED -->

---

## GraphQL API

Ponder auto-generates a GraphQL API at `http://localhost:42069/graphql`.

Example query:

```graphql
{
  claims(limit: 10, orderBy: "submittedAt", orderDirection: "desc") {
    items {
      id
      submitter
      bond
      status
      selfDeclaredDomain
      confidenceScore
      submittedAt
      noveltyPassed
    }
    totalCount
  }
}
```

Filter by status and domain:

```graphql
{
  claims(where: { status: "Pending", selfDeclaredDomain: 2 }) {
    items { id submitter status }
  }
}
```

---

## Source Layout

```
indexer/
├── ponder.config.ts      # Network, contract addresses, ABIs
├── ponder.schema.ts      # onchainTable definitions (Ponder 0.7 / Drizzle)
├── src/
│   └── index.ts          # Event handlers (ponder.on("Contract:Event", ...))
├── package.json
└── tsconfig.json
```

---

## Environment Variables

<!-- AUTO-GENERATED from indexer/ponder.config.ts -->

| Variable | Required | Description |
|----------|----------|-------------|
| `BASE_RPC_URL` | No | Base Sepolia RPC (default: https://sepolia.base.org) |
| `DEPLOY_BLOCK` | No | Start block for indexing (default: 40666128) |
| `CLAIM_REGISTRY_ADDRESS` | No | Overrides hardcoded default |
| `CHALLENGE_WINDOW_ADDRESS` | No | Overrides hardcoded default |
| `ORACLE_ROUTER_ADDRESS` | No | Overrides hardcoded default |
| `INTERNAL_VOTE_ADDRESS` | No | Overrides hardcoded default |
| `EMISSION_CONTROLLER_ADDRESS` | No | Overrides hardcoded default |
| `PONDER_PORT` | Yes (PM2) | Port for Ponder HTTP server — must be `42069` |

`PONDER_PORT` is set in `ecosystem.config.cjs` and is required by Ponder 0.7 to bind to a specific port. Without it, Ponder binds to port 0 (random ephemeral).

<!-- END AUTO-GENERATED -->

---

## Known Behaviour

- **First-run sync:** Ponder must replay all blocks from `DEPLOY_BLOCK` to current head before the HTTP server starts accepting requests. Allow up to 300s on cold start.
- **`@/generated` virtual module:** Resolved by Ponder's internal bundler at runtime. The `paths` alias in `tsconfig.json` (`@/* → .ponder/types/*`) enables IDE type-checking only.
- **Drizzle ORM API:** Ponder 0.7 uses `onchainTable` + Drizzle column types. The older `createSchema` / `p.createTable` API is NOT available in this version.
