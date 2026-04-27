# Node.js API Service

**Port:** 3000
**Technology:** Node.js + TypeScript + Express
**PM2 name:** `plot-oracle-3000`
**Runtime:** `tsx` (no compilation step; PM2 invokes `tsx src/index.ts` directly)

**Status: Implemented and running on Base Sepolia testnet**

---

## What It Does

The Node.js API is the primary entry point for users and AI agents interacting with Plot Protocol.
It sits between the user and the on-chain contracts, handling:

1. **Claim submission** — accepts claim text, calls ClaimRegistry on-chain, runs SNS novelty check, relays result to NoveltyGate
2. **Novelty relay** — calls SNS service, then submits result to NoveltyGate on-chain via the relay signer wallet
3. **Query layer** — proxies claim list queries to the Ponder indexer (GraphQL), falls back to direct chain reads for individual claims
4. **Duplicate detection** — checks `contentHashToClaim()` before submitting to reject exact duplicates

---

## API Endpoints

### Health

```
GET /health
```

Response: `{"status":"ok","service":"plot-oracle-backend","version":"0.1.0"}`

### Claims

```
POST /claims                Submit a new claim
GET  /claims                List claims (paginated, filterable by domain/status)
GET  /claims/:claimId       Get a single claim (direct on-chain read)
```

---

## POST /claims — Submission Flow

<!-- AUTO-GENERATED from backend/src/routes/claims.ts -->

**Request body:**

```json
{
  "claim_text": "string (min 10 chars, required)",
  "domain": "General | Science | Finance | Medical | Regulatory | NationalSecurity (default: General)",
  "complexity": "LOW | MEDIUM | HIGH | VERY_HIGH (default: MEDIUM)",
  "sources": ["https://..."],
  "submitter_address": "0x... (required)"
}
```

**Orchestration steps:**

1. `keccak256(JSON.stringify({text, domain, sources, submitter, timestamp}))` → `contentHash`
2. `ClaimRegistry.contentHashToClaim(contentHash)` — reject with 409 if exact duplicate
3. `BondCalculator.calculateBond(domainCode, complexityBps)` → `bondRequired`
4. `ClaimRegistry.submitClaim(contentHash, domainCode, complexityBps, ZeroHash)` → parse `ClaimSubmitted` event for `claimId`
5. `SNS.POST /novelty/check` → novelty result with `similarity_bps` and `nearest_claim_id`
6. `NoveltyGate.submitNoveltyResult(claimId, similarity_bps, nearestIdHex, justificationHash)` — relay signer signs
7. `SNS.POST /novelty/embed` — store embedding for future comparisons

SNS failures are non-fatal: the claim is still submitted, with `novelty_result: null` in the response.

**Complexity → BPS mapping** (matches `BondCalculator` constants):

| complexity | basis points | multiplier |
|------------|--------------|------------|
| LOW        | 10000        | 1×         |
| MEDIUM     | 20000        | 2×         |
| HIGH       | 30000        | 3×         |
| VERY_HIGH  | 50000        | 5×         |

**Domain → enum mapping:** General=0, Science=1, Finance=2, Medical=3, Regulatory=4, NationalSecurity=5

**Response (201):**

```json
{
  "claim_id": "0x...",
  "content_hash": "0x...",
  "bond_required": "100000000",
  "tx_hash": "0x...",
  "novelty_result": {
    "is_novel": true,
    "similarity_bps": 1000,
    "nearest_claim_id": "0x...",
    "justification": "..."
  }
}
```

> **Note:** `bond_required` is informational only. The relay wallet (`PRIVATE_KEY`) is the actual bond payer: it calls `ClaimRegistry.submitClaim()` as `msg.sender`, so BondEscrow deducts from the relay wallet's USDC. The API automatically checks the relay's USDC allowance and calls `usdc.approve(BOND_ESCROW_ADDRESS, MaxUint256)` once if needed — no manual approval step required.

<!-- END AUTO-GENERATED -->

---

## GET /claims — List Claims

Proxies a GraphQL query to Ponder at `http://localhost:42069/graphql`.

**Query parameters:**

| Param | Description |
|-------|-------------|
| `limit` | Max results (capped at 100, default 20) |
| `offset` | Pagination offset (default 0) |
| `status` | Filter by status string (`Submitted`, `Pending`, `Disputed`, `Verified`, `Rejected`, `Superseded`) |
| `domain` | Filter by domain code (integer 0–5) |

**Response:** `{ items: [...], totalCount: N }`

Returns 502 if the Ponder indexer is not reachable.

---

## GET /claims/:claimId — Get Claim

Direct on-chain read via `ClaimRegistry.getClaim(claimId)`.

**Response:**

```json
{
  "id": "0x...",
  "content_hash": "0x...",
  "submitter": "0x...",
  "bond": "100000000",
  "status": "Submitted",
  "domain": "Finance",
  "voter_domain": null,
  "domain_finalized": false,
  "confidence_score": "0",
  "submitted_at": "1745000000",
  "previous_version": null,
  "next_version": null,
  "novelty_passed": false
}
```

Returns 404 if the submitter is the zero address (claim doesn't exist).

---

## Source Layout

```
backend/
├── src/
│   ├── index.ts          # Express app, /health, mounts claimsRouter
│   ├── lib/
│   │   ├── env.ts        # Loads ../.env (parent dir), exports typed env vars
│   │   ├── contracts.ts  # ethers provider, signer, contract instances
│   │   └── sns.ts        # HTTP client for SNS FastAPI service
│   └── routes/
│       └── claims.ts     # POST/GET /claims handlers
├── package.json
└── tsconfig.json
```

The `.env` file is loaded from the **parent directory** (`../`) because PM2 sets `cwd` to `backend/` and the project root `.env` is one level up.

---

## Environment Variables

<!-- AUTO-GENERATED from backend/src/lib/env.ts -->

| Variable | Required | Description |
|----------|----------|-------------|
| `PORT` | No | Listen port (default: 3000) |
| `BASE_RPC_URL` | Yes | Base RPC endpoint |
| `PRIVATE_KEY` | Yes | Relay signer wallet private key (0x-prefixed) |
| `CLAIM_REGISTRY_ADDRESS` | Yes | ClaimRegistry contract address |
| `NOVELTY_GATE_ADDRESS` | Yes | NoveltyGate contract address |
| `BOND_CALCULATOR_ADDRESS` | Yes | BondCalculator contract address |
| `BOND_ESCROW_ADDRESS` | Yes | BondEscrow contract address (relay auto-approves USDC to this) |
| `SNS_SERVICE_URL` | No | SNS service base URL (default: http://localhost:8000) |
| `PONDER_URL` | No | Ponder indexer base URL (default: http://localhost:42069) |

<!-- END AUTO-GENERATED -->

---

## Scripts

<!-- AUTO-GENERATED from backend/package.json -->

| Command | Description |
|---------|-------------|
| `bun run dev` | Start with tsx (hot reload via tsx watch) |
| `bun run build` | Compile TypeScript to `dist/` |
| `bun run start` | Run compiled output (production) |

<!-- END AUTO-GENERATED -->

PM2 uses `tsx src/index.ts` directly (the `dev` script equivalent) — no build step required.
