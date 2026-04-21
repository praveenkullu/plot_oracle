import logging

from fastapi import APIRouter, Depends, HTTPException

from ..embeddings import EmbeddingService
from ..models import (
    AddEmbeddingRequest,
    AddEmbeddingResponse,
    NoveltyCheckRequest,
    NoveltyCheckResponse,
    NoveltyClassification,
    NoveltyJustification,
)
from ..config import settings

router = APIRouter(prefix="/novelty", tags=["novelty"])
logger = logging.getLogger(__name__)

# Module-level singleton set at startup; overrideable for tests
_embedding_service: EmbeddingService | None = None


def get_embedding_service() -> EmbeddingService:
    if _embedding_service is None:
        raise RuntimeError("EmbeddingService not initialized")
    return _embedding_service


def set_embedding_service(svc: EmbeddingService) -> None:
    global _embedding_service
    _embedding_service = svc


def _classify(score: float) -> str:
    if score >= settings.novelty_flag_threshold:
        return NoveltyClassification.DUPLICATE
    if score >= settings.novelty_reject_threshold:
        return NoveltyClassification.FLAGGED
    return NoveltyClassification.NOVEL


def _novel_elements(score: float, nearest_id: str | None) -> list[str]:
    if nearest_id is None or score < 0.50:
        return ["No similar claims found in this domain"]
    if score < settings.novelty_reject_threshold:
        return [f"Similarity {score:.3f} below rejection threshold — distinct enough to proceed"]
    return []


@router.post("/check", response_model=NoveltyCheckResponse)
async def check_novelty(
    req: NoveltyCheckRequest,
    svc: EmbeddingService = Depends(get_embedding_service),
) -> NoveltyCheckResponse:
    vector = svc.encode(req.claim_text)
    hits = svc.search(vector, req.domain, top_k=1)

    if hits:
        top = hits[0]
        similarity = float(top.score)
        nearest_claim_id: str | None = top.payload.get("claim_id")
    else:
        similarity = 0.0
        nearest_claim_id = None

    classification = _classify(similarity)
    is_novel = classification == NoveltyClassification.NOVEL

    justification = NoveltyJustification(
        nearest_existing_claim=nearest_claim_id,
        similarity_score=similarity,
        novel_elements=_novel_elements(similarity, nearest_claim_id),
    )

    logger.info(
        "Novelty check claim=%s domain=%s score=%.4f novel=%s",
        req.claim_id, req.domain.name, similarity, is_novel,
    )

    return NoveltyCheckResponse(
        claim_id=req.claim_id,
        is_novel=is_novel,
        similarity_score=similarity,
        similarity_bps=int(similarity * 10000),
        classification=classification,
        justification=justification,
        nearest_claim_id=nearest_claim_id,
    )


@router.post("/embed", response_model=AddEmbeddingResponse)
async def add_embedding(
    req: AddEmbeddingRequest,
    svc: EmbeddingService = Depends(get_embedding_service),
) -> AddEmbeddingResponse:
    try:
        vector = svc.encode(req.claim_text)
        svc.upsert(req.claim_id, vector, req.domain, req.content_hash)
        return AddEmbeddingResponse(success=True, claim_id=req.claim_id, message="Embedding stored")
    except Exception as exc:
        logger.exception("Failed to store embedding for claim=%s", req.claim_id)
        raise HTTPException(status_code=500, detail=str(exc)) from exc
