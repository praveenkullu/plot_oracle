# Module 2: Novelty Detection

**Contracts:** `NoveltyGate.sol`
**Off-chain service:** `services/sns/` (Python FastAPI)

**Role in the system:** First filter after submission. A claim that fails novelty detection is
immediately rejected and the submitter's bond is returned. Only novel claims enter the challenge
window. The on-chain contract (`NoveltyGate`) acts as a bridge: the off-chain Python service
makes the determination, and the NoveltyGate records it immutably on-chain.

**Dependencies:** Module 1 (ClaimRegistry)

---

## Overview: Two Layers of Novelty Detection

### Layer 1 — Exact duplicate (on-chain, free)

When a submitter calls `ClaimRegistry.submitClaim()`, the contract checks:

```solidity
require(contentHashToClaim[contentHash] == bytes32(0), "ClaimRegistry: duplicate content");
```

If any previous claim had the **identical content hash** (keccak256 of the full text), the
submission is rejected immediately, before any bond is pulled. This is cheap and effective for
copy-paste duplicates.

### Layer 2 — Semantic novelty (off-chain + on-chain attestation)

Exact matching misses paraphrases: "Russia invaded Ukraine" and "Russian forces entered Ukrainian
territory" have different hashes but mean the same thing. The **Semantic Novelty Service (SNS)**
catches these by comparing the meaning of text using vector embeddings.

The flow:
1. Off-chain SNS service computes embedding (384-dim vector) for the new claim
2. Searches Qdrant vector DB for the most similar existing claim in the same domain
3. If cosine similarity ≥ 0.90 → claim is likely a paraphrase → reject
4. If cosine similarity < 0.90 → claim is novel → proceed
5. SNS oracle wallet calls `NoveltyGate.submitNoveltyResult()` to commit the result on-chain
6. NoveltyGate calls `ClaimRegistry.recordNoveltyResult()` to finalize status

---

## NoveltyGate — `src/NoveltyGate.sol`

### Purpose

Trustless bridge between the off-chain SNS service and the on-chain ClaimRegistry. Any address
with `SNS_ORACLE_ROLE` can submit a novelty result. The result is stored permanently and
forwarded to ClaimRegistry.

### The `NoveltyRecord` struct

```solidity
struct NoveltyRecord {
    uint16  similarityBps;      // cosine similarity × 10000 (0 = completely novel, 10000 = identical)
    bytes32 justificationHash;  // keccak256 of the JSON justification stored on Arweave
    bytes32 nearestClaimId;     // most similar existing claim (bytes32(0) if none found)
    bool    processed;          // prevents processing the same claim twice
}
```

### submitNoveltyResult()

```solidity
function submitNoveltyResult(
    bytes32 claimId,
    uint16  similarityBps,      // 0-10000
    bytes32 nearestClaimId,
    bytes32 justificationHash
) external onlyRole(SNS_ORACLE_ROLE)
```

What it does:
1. Checks `!noveltyRecords[claimId].processed` — prevents replay
2. Computes `passed = similarityBps < noveltyRejectThresholdBps` (default threshold: 9000 = 0.90)
3. Stores the record immutably
4. Emits `NoveltyResultSubmitted(claimId, passed, similarityBps, nearestClaimId, justificationHash)`
5. Calls `claimRegistry.recordNoveltyResult(claimId, passed)` → claim moves to Pending or Rejected

### Threshold

| similarityBps | Classification | Action |
|--------------|---------------|--------|
| 0 – 8999 | Novel | Passes → Status: Pending |
| 9000 – 9499 | Flagged (similar, may be paraphrase) | Rejected in v1 |
| 9500 – 10000 | Near-certain paraphrase | Rejected |

Default threshold: 9000 (0.90). Governance-adjustable between 5000 (0.50) and 9900 (0.99).

### Why is the threshold governance-adjustable?

Early on, the protocol may want to be permissive (low threshold) to allow more claims through
while the voter community grows. As the database of verified claims grows and paraphrase spam
increases, governance can tighten the threshold.

---

## SNS Service — `services/sns/`

### What it does

The Semantic Novelty Service is a Python FastAPI application that:
1. Loads a sentence-transformer model (`all-MiniLM-L6-v2`, 384 dimensions) at startup
2. For each new claim: encodes it to a 384-dim vector, searches Qdrant for the nearest existing
   claim in the same domain, and returns a similarity score
3. After a verified claim passes: stores its embedding in Qdrant for future comparisons
4. Calls `NoveltyGate.submitNoveltyResult()` on-chain (via a keeper wallet) with the result

### Running the service

```bash
# Start with PM2 (port 8000)
~/.local/bin/pm2 start plot-oracle-8000

# Or run directly
cd services/sns
uvicorn app.main:app --host 0.0.0.0 --port 8000

# Health check
curl http://localhost:8000/health
```

### API Endpoints

#### `POST /novelty/check` — Check if a claim is novel

Request:
```json
{
  "claim_id": "0xabc123...",
  "claim_text": "Russia has cut off gas supply to Germany.",
  "domain": "Finance"
}
```

Response:
```json
{
  "claim_id": "0xabc123...",
  "is_novel": true,
  "similarity_score": 0.7231,
  "similarity_bps": 7231,
  "classification": "NOVEL",
  "justification": {
    "nearest_existing_claim": "0xdef456...",
    "similarity_score": 0.7231,
    "novel_elements": ["Similarity 0.723 below rejection threshold — distinct enough to proceed"]
  },
  "nearest_claim_id": "0xdef456..."
}
```

Classifications:
- `"NOVEL"` — similarity < 0.90, safe to proceed
- `"FLAGGED"` — similarity 0.90–0.95, likely paraphrase (rejected in v1)
- `"DUPLICATE"` — similarity ≥ 0.95, near-certain paraphrase (rejected)

#### `POST /novelty/embed` — Store an embedding for a verified claim

Called after a claim is verified (either unchallenged or dispute won), to add its embedding
to Qdrant so future claims can be compared against it.

Request:
```json
{
  "claim_id": "0xabc123...",
  "claim_text": "Russia has cut off gas supply to Germany.",
  "domain": "Finance",
  "content_hash": "0x..."
}
```

### Configuration — `app/config.py`

Key settings (set via environment variables or defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `EMBEDDING_MODEL` | `all-MiniLM-L6-v2` | HuggingFace sentence transformer model |
| `EMBEDDING_DIM` | `384` | Vector size for this model |
| `QDRANT_HOST` | `localhost` | Qdrant server hostname |
| `QDRANT_PORT` | `6333` | Qdrant server port |
| `QDRANT_IN_MEMORY` | `false` | `true` for tests — uses in-process Qdrant |
| `COLLECTION_NAME` | `plot_claims` | Qdrant collection name |
| `NOVELTY_REJECT_THRESHOLD` | `0.90` | Similarity above which claim is rejected |
| `NOVELTY_FLAG_THRESHOLD` | `0.95` | Similarity above which classification is DUPLICATE |

### Architecture — `app/embeddings.py`

The service uses the **abstract / concrete** pattern for testability:

```python
class EmbeddingService(ABC):
    def encode(self, text: str) -> list[float]: ...
    def search(self, vector, domain, top_k=1) -> list[ScoredHit]: ...
    def upsert(self, claim_id, vector, domain, content_hash) -> None: ...
    def count(self, domain=None) -> int: ...
```

Production: `SNSEmbeddingService` — uses real `sentence_transformers` + `qdrant_client`
Tests: `MockEmbeddingService` — in-memory list, no model loaded, fast

This separation means tests run instantly without downloading a 90MB model.

### Qdrant vector search

Qdrant stores vectors in a collection called `plot_claims`. Each point has:
- `id`: integer derived from `hash(claim_id)`
- `vector`: 384-dim float array (normalized cosine)
- `payload`: `{claim_id, domain, content_hash}`

When checking novelty for a new claim, the search is filtered by `domain` — a Finance claim is
only compared against other Finance claims. This prevents cross-domain false positives
(a science claim about inflation and a finance claim about the same topic are related but
belong to separate verification universes).

### Running tests

```bash
cd services/sns
python -m pytest tests/ -v
```

All tests use the mock embedding service. No Qdrant server or model download required.

---

## How NoveltyGate Connects to the Rest

```
Off-chain: SNS service computes similarity → calls NoveltyGate.submitNoveltyResult()
                                                          │
                                               ┌──────────┴──────────┐
                                               │  NoveltyGate        │
                                               │  stores record,     │
                                               │  determines passed  │
                                               └──────────┬──────────┘
                                                          │
                                             ClaimRegistry.recordNoveltyResult()
                                                          │
                                              ┌───────────┴───────────┐
                                         passed=true            passed=false
                                              │                        │
                                       Status: Pending          Status: Rejected
                                              │                   (bond returned)
                                       → ChallengeWindow
```

After a claim is verified (passes all checks), the keeper also calls `POST /novelty/embed` to
store the new claim's embedding in Qdrant so future similar claims are caught.
