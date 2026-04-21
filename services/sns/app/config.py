from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SNS_", env_file=".env")

    qdrant_host: str = "localhost"
    qdrant_port: int = 6333
    qdrant_in_memory: bool = True  # False in production with persistent Qdrant
    embedding_model: str = "all-MiniLM-L6-v2"
    collection_name: str = "claims"
    embedding_dim: int = 384  # all-MiniLM-L6-v2 output dimension
    # Thresholds in [0.0, 1.0] — must match NoveltyGate.sol thresholdBps / 10000
    novelty_reject_threshold: float = 0.90
    novelty_flag_threshold: float = 0.95  # reserved for future higher-bond tier


settings = Settings()
