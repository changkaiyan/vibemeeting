from dataclasses import dataclass
import os


@dataclass(frozen=True)
class SttWorkerConfig:
    host: str = "127.0.0.1"
    port: int = 8765
    provider: str = "mock"
    model_size: str = "small"
    compute_type: str = "int8"
    language: str = "zh"


def load_config() -> SttWorkerConfig:
    return SttWorkerConfig(
        host=(os.getenv("STT_WORKER_HOST", "127.0.0.1") or "127.0.0.1").strip(),
        port=int(os.getenv("STT_WORKER_PORT", "8765")),
        provider=(os.getenv("STT_WORKER_PROVIDER", "mock") or "mock").strip(),
        model_size=(os.getenv("STT_WORKER_MODEL_SIZE", "small") or "small").strip(),
        compute_type=(os.getenv("STT_WORKER_COMPUTE_TYPE", "int8") or "int8").strip(),
        language=(os.getenv("STT_WORKER_LANGUAGE", "zh") or "zh").strip(),
    )
