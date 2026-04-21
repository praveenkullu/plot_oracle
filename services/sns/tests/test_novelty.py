import pytest


CLAIM_PAYLOAD = {
    "claim_id": "0xabc123",
    "claim_text": "The Federal Reserve raised interest rates by 25 basis points in March 2024.",
    "domain": 2,  # Finance
    "content_hash": "0x" + "a" * 64,
}

EMBED_PAYLOAD = {
    "claim_id": "0xdef456",
    "claim_text": "Inflation declined to 3.1% in the United States in February 2024.",
    "domain": 2,
    "content_hash": "0x" + "b" * 64,
}


def test_health(client):
    c, _ = client
    r = c.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_novel_claim_passes(client):
    c, svc = client
    svc.next_score = 0.65  # well below 0.90 threshold
    r = c.post("/novelty/check", json=CLAIM_PAYLOAD)
    assert r.status_code == 200
    data = r.json()
    assert data["is_novel"] is True
    assert data["classification"] == "novel"
    assert data["similarity_bps"] == 6500
    assert data["similarity_score"] == pytest.approx(0.65)


def test_duplicate_claim_rejected(client):
    c, svc = client
    svc.next_score = 0.97  # above flag threshold 0.95
    r = c.post("/novelty/check", json=CLAIM_PAYLOAD)
    assert r.status_code == 200
    data = r.json()
    assert data["is_novel"] is False
    assert data["classification"] == "duplicate"
    assert data["similarity_bps"] == 9700


def test_flagged_claim_not_novel(client):
    c, svc = client
    svc.next_score = 0.92  # between 0.90 and 0.95
    r = c.post("/novelty/check", json=CLAIM_PAYLOAD)
    assert r.status_code == 200
    data = r.json()
    assert data["is_novel"] is False
    assert data["classification"] == "flagged"


def test_no_existing_claims_is_novel(client):
    c, svc = client
    svc.next_score = 0.0
    svc.next_nearest_id = None
    r = c.post("/novelty/check", json=CLAIM_PAYLOAD)
    assert r.status_code == 200
    data = r.json()
    assert data["is_novel"] is True
    assert data["nearest_claim_id"] is None


def test_add_embedding_stores_claim(client):
    c, svc = client
    r = c.post("/novelty/embed", json=EMBED_PAYLOAD)
    assert r.status_code == 200
    data = r.json()
    assert data["success"] is True
    assert data["claim_id"] == "0xdef456"
    assert len(svc.stored) == 1
    assert svc.stored[0]["claim_id"] == "0xdef456"


def test_novelty_check_returns_nearest_claim_id(client):
    c, svc = client
    svc.next_score = 0.75
    svc.next_nearest_id = "0xcafe"
    r = c.post("/novelty/check", json=CLAIM_PAYLOAD)
    assert r.status_code == 200
    data = r.json()
    assert data["nearest_claim_id"] == "0xcafe"
    assert data["justification"]["nearest_existing_claim"] == "0xcafe"


def test_short_claim_text_rejected(client):
    c, _ = client
    payload = {**CLAIM_PAYLOAD, "claim_text": "short"}
    r = c.post("/novelty/check", json=payload)
    assert r.status_code == 422


def test_invalid_domain_rejected(client):
    c, _ = client
    payload = {**CLAIM_PAYLOAD, "domain": 99}
    r = c.post("/novelty/check", json=payload)
    assert r.status_code == 422
