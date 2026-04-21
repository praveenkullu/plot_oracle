import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from .embeddings import SNSEmbeddingService
from .routers import novelty
from .routers.novelty import set_embedding_service

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


@asynccontextmanager
async def lifespan(app: FastAPI):
    set_embedding_service(SNSEmbeddingService())
    yield


app = FastAPI(
    title="Plot Protocol — Semantic Novelty Service",
    description="Layer 2 novelty detection: sentence transformer embeddings + cosine similarity via Qdrant.",
    version="0.1.0",
    lifespan=lifespan,
)

app.include_router(novelty.router)


@app.get("/health")
async def health() -> JSONResponse:
    return JSONResponse({"status": "ok"})
