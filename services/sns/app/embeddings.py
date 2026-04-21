from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from typing import Any

from .config import settings
from .models import Domain

logger = logging.getLogger(__name__)


class ScoredHit:
    """Minimal hit type — mirrors qdrant_client ScoredPoint interface."""
    def __init__(self, score: float, payload: dict):
        self.score = score
        self.payload = payload


class EmbeddingService(ABC):
    @abstractmethod
    def encode(self, text: str) -> list[float]: ...

    @abstractmethod
    def search(self, vector: list[float], domain: Domain, top_k: int = 1) -> list[ScoredHit]: ...

    @abstractmethod
    def upsert(self, claim_id: str, vector: list[float], domain: Domain, content_hash: str) -> None: ...

    @abstractmethod
    def count(self, domain: Domain | None = None) -> int: ...


class SNSEmbeddingService(EmbeddingService):
    """Production implementation using sentence-transformers + Qdrant."""

    def __init__(self) -> None:
        # Lazy imports — only required in production, not test
        from qdrant_client import QdrantClient
        from qdrant_client.models import Distance, VectorParams
        from sentence_transformers import SentenceTransformer

        logger.info("Loading embedding model: %s", settings.embedding_model)
        self._model = SentenceTransformer(settings.embedding_model)

        if settings.qdrant_in_memory:
            self._client = QdrantClient(":memory:")
        else:
            self._client = QdrantClient(host=settings.qdrant_host, port=settings.qdrant_port)

        self._QdrantClient = QdrantClient
        self._Distance = Distance
        self._VectorParams = VectorParams
        self._ensure_collection()

    def _ensure_collection(self) -> None:
        from qdrant_client.models import VectorParams, Distance
        existing = {c.name for c in self._client.get_collections().collections}
        if settings.collection_name not in existing:
            self._client.create_collection(
                collection_name=settings.collection_name,
                vectors_config=VectorParams(size=settings.embedding_dim, distance=Distance.COSINE),
            )
            logger.info("Created Qdrant collection: %s", settings.collection_name)

    def encode(self, text: str) -> list[float]:
        return self._model.encode(text, normalize_embeddings=True).tolist()

    def search(self, vector: list[float], domain: Domain, top_k: int = 1) -> list[ScoredHit]:
        from qdrant_client.models import Filter, FieldCondition, MatchValue
        hits = self._client.search(
            collection_name=settings.collection_name,
            query_vector=vector,
            query_filter=Filter(
                must=[FieldCondition(key="domain", match=MatchValue(value=domain.value))]
            ),
            limit=top_k,
            with_payload=True,
        )
        return [ScoredHit(h.score, h.payload) for h in hits]

    def upsert(self, claim_id: str, vector: list[float], domain: Domain, content_hash: str) -> None:
        from qdrant_client.models import PointStruct
        point_id = abs(hash(claim_id)) % (2**63)
        self._client.upsert(
            collection_name=settings.collection_name,
            points=[
                PointStruct(
                    id=point_id,
                    vector=vector,
                    payload={"claim_id": claim_id, "domain": domain.value, "content_hash": content_hash},
                )
            ],
        )

    def count(self, domain: Domain | None = None) -> int:
        from qdrant_client.models import Filter, FieldCondition, MatchValue
        if domain is None:
            return self._client.count(collection_name=settings.collection_name).count
        return self._client.count(
            collection_name=settings.collection_name,
            count_filter=Filter(
                must=[FieldCondition(key="domain", match=MatchValue(value=domain.value))]
            ),
        ).count
