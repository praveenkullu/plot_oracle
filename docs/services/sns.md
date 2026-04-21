# SNS — Semantic Novelty Service

**Location:** `services/sns/`
**Port:** 8000
**Technology:** Python 3.11 + FastAPI + sentence-transformers + Qdrant

**Status: Implemented** (see `services/sns/`)

---

## What It Does

The SNS service is the off-chain component of Module 2 (Novelty Detection). When a new claim is
submitted, the Node.js API calls this service to check whether the claim is semantically similar
to existing verified claims. If similarity ≥ 0.90, the claim is a likely paraphrase and is rejected.

The service does two things:
1. **Check novelty** (`/novelty/check`): encode new claim → search Qdrant → return score
2. **Store embeddings** (`/novelty/embed`): after a claim is verified, store its vector in Qdrant
   so future claims can be compared against it

---

## Architecture

```
services/sns/
├── app/
│   ├── main.py           FastAPI app, startup, health check
│   ├── config.py         Settings (model, Qdrant, thresholds)
│   ├── models.py         Pydantic schemas for requests/responses
│   ├── embeddings.py     Abstract EmbeddingService + SNSEmbeddingService (production)
│   └── routers/
│       └── novelty.py    /novelty/check and /novelty/embed endpoints
└── tests/
    ├── conftest.py       MockEmbeddingService, FastAPI test client setup
    └── test_novelty.py   All SNS tests
```

### Key design: EmbeddingService abstraction

```python
class EmbeddingService(ABC):
    def encode(self, text: str) -> list[float]: ...       # text → vector
    def search(self, vector, domain, top_k=1) -> list[ScoredHit]: ...  # nearest neighbors
    def upsert(self, claim_id, vector, domain, content_hash) -> None: ...  # store
    def count(self, domain=None) -> int: ...               # collection size
```

**Production:** `SNSEmbeddingService` — loads `all-MiniLM-L6-v2` model (90MB), connects to Qdrant
**Tests:** `MockEmbeddingService` — in-memory dict, no model, fast

At startup, `lifespan()` creates `SNSEmbeddingService()` and injects it into the router via
`Depends(get_embedding_service)`. Tests override this with `set_embedding_service(MockService())`.

---

## Configuration

All settings are in `app/config.py` using Pydantic Settings (reads from environment variables):

```python
class Settings(BaseSettings):
    embedding_model:        str   = "all-MiniLM-L6-v2"
    embedding_dim:          int   = 384
    qdrant_host:            str   = "localhost"
    qdrant_port:            int   = 6333
    qdrant_in_memory:       bool  = False   # True in tests
    collection_name:        str   = "plot_claims"
    novelty_reject_threshold: float = 0.90  # FLAGGED threshold
    novelty_flag_threshold:   float = 0.95  # DUPLICATE threshold
```

Set via environment variables (prefixed automatically by Pydantic):
```env
EMBEDDING_MODEL=all-MiniLM-L6-v2
QDRANT_IN_MEMORY=false
QDRANT_HOST=localhost
NOVELTY_REJECT_THRESHOLD=0.90
```

---

## API Reference

### `GET /health`

```json
{"status": "ok"}
```

### `POST /novelty/check`

Check if a new claim is semantically novel.

**Request:**
```json
{
  "claim_id": "0xabc...",          // On-chain claim ID (bytes32 hex string)
  "claim_text": "Full claim text", // The actual claim content
  "domain": "Finance"              // One of: General, Science, Finance, Medical, Regulatory, NationalSecurity
}
```

**Response:**
```json
{
  "claim_id": "0xabc...",
  "is_novel": true,                // false if classification is FLAGGED or DUPLICATE
  "similarity_score": 0.7231,      // 0.0-1.0 cosine similarity with nearest claim
  "similarity_bps": 7231,          // same value × 10000 (for on-chain use)
  "classification": "NOVEL",       // NOVEL | FLAGGED | DUPLICATE
  "justification": {
    "nearest_existing_claim": "0xdef...",   // null if no similar claims found
    "similarity_score": 0.7231,
    "novel_elements": ["..."]
  },
  "nearest_claim_id": "0xdef..."   // null if nothing found
}
```

**Classification thresholds:**
| similarity_score | classification | is_novel |
|-----------------|---------------|----------|
| < 0.90 | `NOVEL` | `true` |
| 0.90 – 0.95 | `FLAGGED` | `false` |
| ≥ 0.95 | `DUPLICATE` | `false` |

### `POST /novelty/embed`

Store an embedding for a verified claim (called after claim is verified on-chain).

**Request:**
```json
{
  "claim_id": "0xabc...",
  "claim_text": "Full claim text",
  "domain": "Finance",
  "content_hash": "0x..."   // keccak256 of claim text (for Qdrant payload)
}
```

**Response:**
```json
{
  "success": true,
  "claim_id": "0xabc...",
  "message": "Embedding stored"
}
```

---

## Domain Filtering

Claims are compared only within the same domain. A Finance claim is never compared against a
Science claim — this prevents false positives from cross-domain topic overlap.

Qdrant stores `domain` in the payload and each search includes a filter:
```python
Filter(must=[FieldCondition(key="domain", match=MatchValue(value=domain.value))])
```

---

## Running

```bash
# Development
cd services/sns
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

# Production via PM2
~/.local/bin/pm2 start plot-oracle-8000

# Tests
python -m pytest tests/ -v
python -m pytest tests/ -v --tb=short  # brief output
```

### First run: model download

On first startup, `SNSEmbeddingService` downloads `all-MiniLM-L6-v2` from HuggingFace (~90MB).
This is cached in `~/.cache/huggingface/` and not re-downloaded on subsequent starts.

To pre-download:
```bash
python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"
```

---

## Tests

```bash
cd services/sns
python -m pytest tests/ -v
```

Tests use `MockEmbeddingService` — no model required, no Qdrant required. The mock stores
vectors in an in-memory list and returns the closest by cosine similarity.

Key test scenarios:
- `test_check_novel_claim` — score 0.0, no similar claims → `NOVEL`
- `test_check_similar_claim_flagged` — score 0.91 → `FLAGGED`, is_novel=false
- `test_check_duplicate_claim` — score 0.96 → `DUPLICATE`
- `test_embed_and_check_returns_novel_elements` — stored claim appears in results
- `test_health_check` — `/health` returns 200 OK

---

## Integration with On-Chain Contracts

After `/novelty/check` returns, the Node.js API (or the SNS oracle keeper) calls
`NoveltyGate.submitNoveltyResult()` with:
- `claimId` — the on-chain bytes32 claim ID
- `similarityBps` — `similarity_bps` from the response
- `nearestClaimId` — `nearest_claim_id` converted to bytes32 (bytes32(0) if null)
- `justificationHash` — keccak256 of the JSON justification uploaded to Arweave

The SNS oracle wallet must hold `SNS_ORACLE_ROLE` on the deployed `NoveltyGate` contract.

```typescript
// Example (Node.js API side)
const result = await fetch('http://localhost:8000/novelty/check', { ... });
const noveltyData = await result.json();

// Upload justification to Arweave
const justificationHash = await irys.upload(JSON.stringify(noveltyData.justification));

// Submit on-chain
await noveltyGate.submitNoveltyResult(
  claimId,
  noveltyData.similarity_bps,
  noveltyData.nearest_claim_id ? toBytes32(noveltyData.nearest_claim_id) : ethers.ZeroHash,
  justificationHash
);
```
