from dataclasses import dataclass
import os
from pathlib import Path


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    return default


@dataclass(frozen=True)
class MeetingAgentBridgeConfig:
    host: str = "127.0.0.1"
    port: int = 8787
    workspace_root: Path = Path(".")
    codex_bin: str = "codex"
    codex_model: str = ""
    timeout_seconds: int = 90
    enable_claude_via_codex: bool = False


def load_config() -> MeetingAgentBridgeConfig:
    workspace_root = Path(
        (os.getenv("MEETING_AGENT_BRIDGE_WORKSPACE_ROOT", ".") or ".").strip()
    ).expanduser()
    return MeetingAgentBridgeConfig(
        host=(os.getenv("MEETING_AGENT_BRIDGE_HOST", "127.0.0.1") or "127.0.0.1").strip(),
        port=int(os.getenv("MEETING_AGENT_BRIDGE_PORT", "8787")),
        workspace_root=workspace_root,
        codex_bin=(os.getenv("MEETING_AGENT_BRIDGE_CODEX_BIN", "codex") or "codex").strip(),
        codex_model=(os.getenv("MEETING_AGENT_BRIDGE_CODEX_MODEL", "") or "").strip(),
        timeout_seconds=int(os.getenv("MEETING_AGENT_BRIDGE_TIMEOUT_SECONDS", "90")),
        enable_claude_via_codex=_env_bool("MEETING_AGENT_BRIDGE_ENABLE_CLAUDE_VIA_CODEX", False),
    )
