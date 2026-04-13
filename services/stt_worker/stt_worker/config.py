from dataclasses import dataclass
import os
from pathlib import Path


def _env_bool(name: str, default: bool) -> bool:
    raw = _env(name, "")
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized == "":
        return default
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    return default


@dataclass(frozen=True)
class SttWorkerConfig:
    host: str = "127.0.0.1"
    port: int = 8765
    provider: str = "mock"
    model_size: str = "small"
    compute_type: str = "int8"
    language: str = "zh"
    local_files_only: bool = False
    volcengine_app_id: str = ""
    volcengine_access_token: str = ""
    volcengine_resource_id: str = ""
    volcengine_ws_url: str = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _load_repo_env_defaults() -> dict[str, str]:
    env_path = _repo_root() / ".env"
    if not env_path.exists():
        return {}

    defaults: dict[str, str] = {}
    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            continue
        defaults[key] = value.strip()
    return defaults


def _env(name: str, default: str) -> str:
    raw = os.getenv(name)
    if raw is not None:
        return raw
    return _load_repo_env_defaults().get(name, default)


def load_config() -> SttWorkerConfig:
    return SttWorkerConfig(
        host=(_env("STT_WORKER_HOST", "127.0.0.1") or "127.0.0.1").strip(),
        port=int(_env("STT_WORKER_PORT", "8765")),
        provider=(_env("STT_WORKER_PROVIDER", "mock") or "mock").strip(),
        model_size=(_env("STT_WORKER_MODEL_SIZE", "small") or "small").strip(),
        compute_type=(_env("STT_WORKER_COMPUTE_TYPE", "int8") or "int8").strip(),
        language=(_env("STT_WORKER_LANGUAGE", "zh") or "zh").strip(),
        local_files_only=_env_bool("STT_WORKER_LOCAL_FILES_ONLY", False),
        volcengine_app_id=(_env("STT_WORKER_VOLCENGINE_APP_ID", "") or "").strip(),
        volcengine_access_token=(_env("STT_WORKER_VOLCENGINE_ACCESS_TOKEN", "") or "").strip(),
        volcengine_resource_id=(_env("STT_WORKER_VOLCENGINE_RESOURCE_ID", "") or "").strip(),
        volcengine_ws_url=(
            _env("STT_WORKER_VOLCENGINE_WS_URL", "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")
            or "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"
        ).strip(),
    )
