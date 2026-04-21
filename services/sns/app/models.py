from enum import IntEnum
from pydantic import BaseModel, Field


class Domain(IntEnum):
    General = 0
    Science = 1
    Finance = 2
    Medical = 3
    Regulatory = 4
    NationalSecurity = 5


class NoveltyClassification(str):
    NOVEL = "novel"            # < reject_threshold → passes gate
    FLAGGED = "flagged"        # reject_threshold <= score < flag_threshold (future higher-bond tier)
    DUPLICATE = "duplicate"    # >= flag_threshold → auto-reject


class NoveltyCheckRequest(BaseModel):
    claim_id: str = Field(..., description="On-chain claim ID (bytes32 hex)")
    claim_text: str = Field(..., min_length=10)
    domain: Domain
    content_hash: str = Field(..., description="keccak256 content hash (bytes32 hex)")


class NoveltyJustification(BaseModel):
    nearest_existing_claim: str | None = None
    similarity_score: float
    novel_elements: list[str] = []


class NoveltyCheckResponse(BaseModel):
    claim_id: str
    is_novel: bool
    similarity_score: float = Field(..., ge=0.0, le=1.0)
    similarity_bps: int = Field(..., ge=0, le=10000, description="similarity_score * 10000 for on-chain use")
    classification: str
    justification: NoveltyJustification
    nearest_claim_id: str | None = None


class AddEmbeddingRequest(BaseModel):
    claim_id: str
    claim_text: str = Field(..., min_length=10)
    domain: Domain
    content_hash: str


class AddEmbeddingResponse(BaseModel):
    success: bool
    claim_id: str
    message: str = ""
