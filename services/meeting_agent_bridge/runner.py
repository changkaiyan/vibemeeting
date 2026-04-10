import json
import shutil
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory

from services.meeting_agent_bridge.config import MeetingAgentBridgeConfig

_ARTIFACT_TYPES = ["summary", "todo", "decision", "code_task", "reply"]


def supported_runner(agent_type: str, config: MeetingAgentBridgeConfig) -> str | None:
    normalized = (agent_type or "").strip().lower()
    if normalized == "codex":
        return "codex"
    if normalized == "claude" and config.enable_claude_via_codex:
        return "codex"
    return None


def health_payload(agent_type: str, config: MeetingAgentBridgeConfig) -> dict:
    runner = supported_runner(agent_type, config)
    if runner != "codex":
        return {
            "ok": False,
            "detail": f"Agent runner is not configured for {agent_type or 'unknown'}",
        }

    codex_path = shutil.which(config.codex_bin)
    if not codex_path:
        return {"ok": False, "detail": f"Codex CLI not found: {config.codex_bin}"}

    try:
        result = subprocess.run(
            [codex_path, "login", "status"],
            cwd=config.workspace_root,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "detail": f"Codex health check failed: {exc}"}

    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "Codex login status failed").strip()
        return {"ok": False, "detail": detail}

    return {
        "ok": True,
        "runner": "codex",
        "agent_type": (agent_type or "").strip().lower(),
        "workspace_root": str(config.workspace_root),
        "model": config.codex_model or "",
    }


def run_action(body: dict, config: MeetingAgentBridgeConfig) -> dict:
    agent_type = (body.get("agent_type") or "").strip().lower()
    runner = supported_runner(agent_type, config)
    if runner != "codex":
        raise RuntimeError(f"Agent runner is not configured for {agent_type or 'unknown'}")
    return _run_codex_action(body, config)


def _run_codex_action(body: dict, config: MeetingAgentBridgeConfig) -> dict:
    codex_path = shutil.which(config.codex_bin)
    if not codex_path:
        raise RuntimeError(f"Codex CLI not found: {config.codex_bin}")

    with TemporaryDirectory(prefix="meeting-agent-bridge-") as temp_dir:
        temp_path = Path(temp_dir)
        schema_path = temp_path / "schema.json"
        output_path = temp_path / "result.json"
        schema_path.write_text(json.dumps(_output_schema(), ensure_ascii=True), encoding="utf-8")

        command = [
            codex_path,
            "exec",
            "--skip-git-repo-check",
            "--color",
            "never",
            "--dangerously-bypass-approvals-and-sandbox",
            "--output-schema",
            str(schema_path),
            "-o",
            str(output_path),
        ]
        if config.codex_model:
            command.extend(["--model", config.codex_model])
        command.append(_build_prompt(body))

        result = subprocess.run(
            command,
            cwd=config.workspace_root,
            capture_output=True,
            text=True,
            timeout=config.timeout_seconds,
            check=False,
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "Codex exec failed").strip()
            raise RuntimeError(detail)
        if not output_path.exists():
            raise RuntimeError("Codex exec finished without a structured output payload")

        try:
            payload = json.loads(output_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Codex returned invalid JSON: {exc}") from exc

    if not isinstance(payload, dict):
        raise RuntimeError("Codex returned an invalid structured payload")
    return payload


def _output_schema() -> dict:
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "short_reply": {"type": "string"},
            "artifact_type": {"type": "string", "enum": _ARTIFACT_TYPES},
            "artifact_title": {"type": "string"},
            "artifact_content": {"type": "string"},
        },
        "required": ["short_reply", "artifact_type", "artifact_title", "artifact_content"],
    }


def _build_prompt(body: dict) -> str:
    task_type = (body.get("task_type") or "").strip().lower()
    artifact_type = _suggest_artifact_type(task_type)
    instruction = (body.get("instruction") or "").strip()
    context = body.get("context") or {}
    chunks = body.get("chunks") or []

    prompt_payload = {
        "meeting_id": body.get("meeting_id"),
        "agent_type": body.get("agent_type"),
        "task_type": task_type,
        "instruction": instruction,
        "context": context,
        "chunks": chunks,
    }
    return (
        "You are a local meeting assistant invoked by an HTTP bridge.\n"
        "Return a JSON object matching the provided schema.\n"
        "Write concise, useful results grounded only in the supplied meeting context.\n"
        "Do not mention the bridge, schema, or internal tooling.\n"
        "The field short_reply must be a plain human-readable sentence, not JSON and not markdown.\n"
        f"Prefer artifact_type={artifact_type!r} unless the task clearly needs another valid type.\n\n"
        "Meeting payload:\n"
        f"{json.dumps(prompt_payload, ensure_ascii=False, indent=2)}\n"
    )


def _suggest_artifact_type(task_type: str) -> str:
    if task_type == "summarize":
        return "summary"
    if task_type == "extract_todos":
        return "todo"
    if task_type == "draft_api":
        return "code_task"
    return "reply"
