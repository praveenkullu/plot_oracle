import pytest
from fastapi.testclient import TestClient

from app.embeddings import EmbeddingService, ScoredHit
from app.models import Domain
from app.routers.novelty import get_embedding_service, set_embedding_service
from app.main import app


class MockEmbeddingService(EmbeddingService):
    def __init__(self):
        self.next_score: float = 0.0
        self.next_nearest_id: str | None = "existing-claim-001"
        self.stored: list[dict] = []

    def encode(self, text: str) -> list[float]:
        return [0.0] * 384

    def search(self, vector, domain, top_k=1):
        if self.next_nearest_id is None:
            return []
        return [ScoredHit(self.next_score, {"claim_id": self.next_nearest_id, "domain": domain.value})]

    def upsert(self, claim_id, vector, domain, content_hash):
        self.stored.append({"claim_id": claim_id, "domain": domain, "content_hash": content_hash})

    def count(self, domain=None):
        return len(self.stored)


@pytest.fixture
def mock_svc():
    return MockEmbeddingService()


@pytest.fixture
def client(mock_svc):
    app.dependency_overrides[get_embedding_service] = lambda: mock_svc
    with TestClient(app) as c:
        yield c, mock_svc
    app.dependency_overrides.clear()
