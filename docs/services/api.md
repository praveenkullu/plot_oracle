# Node.js API Service

**Port:** 3000
**Technology:** Node.js + TypeScript + Express
**PM2 name:** `plot-oracle-3000`

**Status: Architecture defined; implementation pending**

---

## What It Does

The Node.js API is the primary entry point for users and AI agents interacting with Plot Protocol.
It sits between the user and the on-chain contracts, handling:

1. **Claim submission** — accepts claim text, uploads to Arweave, calls ClaimRegistry on-chain
2. **Novelty relay** — calls SNS service, then submits result to NoveltyGate on-chain
3. **Query layer** — exposes claim data indexed by Ponder (no direct chain reads for most queries)
4. **Webhook/notification** — optionally notifies subscribers of claim status changes

---

## Planned API Endpoints

### Claims

```
POST /claims                Submit a new claim
GET  /claims                List claims (paginated, filterable by domain/status)
GET  /claims/:claimId       Get a single claim with full status
GET  /claims/:claimId/window  Get challenge window state
```

### Submission Flow

`POST /claims` orchestrates the entire submission flow:

```typescript
// Request body
{
  "claim_text": "string",         // Full claim text (stored on Arweave)
  "domain": "Finance",            // Self-declared domain
  "complexity": "MEDIUM",         // LOW | MEDIUM | HIGH | VERY_HIGH
  "sources": ["https://..."],     // Source URLs (at least 1 required)
  "submitter_address": "0x...",   // Submitter's wallet address
  "signature": "0x..."            // EIP-712 signature authorizing submission
}

// Response
{
  "claim_id": "0x...",            // On-chain bytes32 claim ID
  "arweave_tx_id": "abc...",      // Arweave transaction ID for full content
  "bond_required": "100000000",   // USDC amount (6 decimals) submitter must approve
  "tx_hash": "0x...",             // ClaimRegistry.submitClaim() transaction hash
  "novelty_result": {
    "is_novel": true,
    "similarity_score": 0.71,
    "classification": "NOVEL"
  }
}
```

### Governance

```
GET  /proposals             List active governance proposals
POST /proposals             Create a new governance proposal (via GovernorPlot)
GET  /proposals/:id         Proposal details + current votes
```

---

## Arweave / Irys Integration

Every claim must be permanently stored on Arweave before the on-chain submission. The API
uses the Irys SDK to upload:

```typescript
import Irys from "@irys/sdk";

const irys = new Irys({
  network: "mainnet",  // or "devnet" for testing
  token: "ethereum",
  key: process.env.IRYS_PRIVATE_KEY,
  config: { providerUrl: process.env.BASE_RPC_URL }
});

// Upload claim content
const claimPayload = {
  text: claimText,
  domain: domain,
  sources: sources,
  submitter: submitterAddress,
  timestamp: Date.now()
};

const receipt = await irys.upload(JSON.stringify(claimPayload), {
  tags: [
    { name: "Content-Type", value: "application/json" },
    { name: "protocol", value: "plot-protocol" },
    { name: "claim-id", value: claimId }
  ]
});

const arweaveTxId = receipt.id;
const contentHash = ethers.keccak256(ethers.toUtf8Bytes(JSON.stringify(claimPayload)));
```

The `contentHash` is then passed to `ClaimRegistry.submitClaim()` as the on-chain pointer.

---

## On-Chain Transaction Relay

The API acts as a gasless relay: users sign an EIP-712 typed message, the API submits the
transaction on their behalf (paying gas), and the user is charged via the bond mechanism.

This enables integration with Coinbase Smart Wallet and gasless onboarding.

For the SNS novelty relay:
```typescript
// After SNS check, the SNS oracle wallet submits on-chain
const tx = await noveltyGate.submitNoveltyResult(
  claimId,
  similarityBps,
  nearestClaimIdBytes32,
  justificationHashBytes32,
  { from: snsOracleWallet }  // must hold SNS_ORACLE_ROLE
);
```

---

## Citation Verification Service (CVS)

The API also runs the Citation Verification Service (CVS) as part of claim submission:

1. Fetch each source URL using Playwright (handles JavaScript-rendered pages)
2. Archive the snapshot to Arweave
3. Compute semantic similarity between claim text and source content
4. Return a Source Grounding Score (0.0 – 1.0)
5. If score < 0.50, the claim is flagged for higher bond (not implemented in v1)

```typescript
// CVS integration point (v2)
const cvs_result = await verifyCitations(claimText, sources);
// cvs_result.groundingScore: 0.0-1.0
// cvs_result.arweaveSnapshots: [txId, txId, ...]
```

---

## Environment Variables

```env
PORT=3000
BASE_RPC_URL=https://mainnet.base.org

# Contract addresses (filled after deployment)
CLAIM_REGISTRY_ADDRESS=0x...
NOVELTY_GATE_ADDRESS=0x...
BOND_ESCROW_ADDRESS=0x...

# SNS service
SNS_SERVICE_URL=http://localhost:8000

# Arweave
IRYS_PRIVATE_KEY=0x...
IRYS_NETWORK=mainnet

# Signing wallet for SNS oracle
SNS_ORACLE_PRIVATE_KEY=0x...
```

---

## Implementation Plan

The Node.js API is not yet implemented. Development order:

1. **Basic Express app** with health check and TypeScript config
2. **Contract ABIs** — import from Foundry build output (`contracts/out/`)
3. **ethers.js integration** — connect to Base, sign/send transactions
4. **Arweave/Irys upload** — claim text persistence
5. **POST /claims** — full submission flow
6. **GET /claims** — query via Ponder indexer
7. **SNS oracle relay** — automatic NoveltyGate.submitNoveltyResult() after SNS check
8. **Keeper bot** — auto-finalize windows, open votes, release bonds
