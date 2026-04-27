# Off-Chain Services

Plot Protocol has three off-chain service layers that complement the on-chain contracts:

| Service | Port | Tech | Purpose |
|---------|------|------|---------|
| **SNS** — Semantic Novelty Service | 8000 | Python + FastAPI | Compute semantic similarity; filter duplicate claims |
| **API** — REST & Event Processor | 3000 | Node.js + TypeScript + Express | Submit claims, query state, relay novelty results on-chain |
| **Indexer** — Event Indexer | 42069 | Ponder.sh | Index Base L2 events; power the API query layer |
| **Keepers** — Claim Finalization | n/a | Bash + cast | Finalize expired windows; release submitter bonds |

## How They Fit Together

```
User / AI Agent
    │
    ▼ HTTP POST /claims
[Node.js API :3000]
    │
    ├── 1. keccak256(payload) → contentHash; duplicate check via contentHashToClaim()
    │
    ├── 2. Call ClaimRegistry.submitClaim() on-chain
    │          (submitter must pre-approve USDC to BondEscrow)
    │
    └── 3. POST /novelty/check to SNS service
               │
    [SNS :8000]├── encode claim text → 384-dim vector
               ├── search Qdrant for nearest claim in same domain
               └── return similarity score, classification
                         │
    [Node.js API]        │
               ◄─────────┘
    │
    └── 4. Call NoveltyGate.submitNoveltyResult() on-chain
               (SNS oracle wallet signs the tx)


[Ponder Indexer :42069]
    ├── Watches ClaimSubmitted, StatusChanged, DomainFinalized, etc.
    ├── Stores in PGlite (embedded Postgres) for fast querying
    └── Powers GET /claims, GET /claims/:id endpoints in Node.js API
```

## Service Documentation

- [SNS Service](sns.md) — Semantic Novelty Service (implemented, running on port 8000)
- [Node.js API](api.md) — REST API and on-chain relay (implemented, running on port 3000)
- [Ponder Indexer](indexer.md) — Event indexer (implemented, running on port 42069)
- [Keeper Scripts](keepers.md) — Claim finalization and bond release automation

## Running Locally

```bash
# All services via PM2
~/.local/bin/pm2 start ecosystem.config.cjs
~/.local/bin/pm2 status

# Or individually
cd services/sns && uvicorn app.main:app --port 8000
```
