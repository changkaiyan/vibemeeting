import json
from time import monotonic
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin
from urllib.request import Request, urlopen

from django.conf import settings

from conference.meeting_agent_bridge.exceptions import (
    MeetingAgentActionError,
    MeetingAgentBridgeUnavailable,
)


def _bridge_base_url() -> str:
    return (getattr(settings, "MEETING_AGENT_BRIDGE_URL", "") or "").strip().rstrip("/")


def bridge_mode() -> str:
    mode = (getattr(settings, "MEETING_AGENT_BRIDGE_MODE", "") or "").strip().lower()
    if mode:
        return mode
    return "http" if _bridge_base_url() else "disabled"


def is_mock_mode() -> bool:
    return bridge_mode() == "mock"


def _timeout_seconds() -> float:
    return float(getattr(settings, "MEETING_AGENT_BRIDGE_TIMEOUT_SECONDS", 20.0) or 20.0)


def _request_json(path: str, *, method: str = "GET", payload: dict | None = None) -> dict:
    base_url = _bridge_base_url()
    if not base_url:
        raise MeetingAgentBridgeUnavailable("Meeting agent bridge URL is not configured")

    request = Request(
        urljoin(f"{base_url}/", path.lstrip("/")),
        data=json.dumps(payload).encode("utf-8") if payload is not None else None,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    try:
        with urlopen(request, timeout=_timeout_seconds()) as response:
            return json.loads(response.read().decode("utf-8"))
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise MeetingAgentBridgeUnavailable("Meeting agent bridge is unavailable") from exc


def ensure_bridge_available(agent_type: str) -> dict:
    mode = bridge_mode()
    if mode == "mock":
        return {"ok": True, "mode": "mock", "agent_type": agent_type}
    if mode != "http":
        raise MeetingAgentBridgeUnavailable("Meeting agent bridge is not configured")

    payload = _request_json(f"health?agent_type={agent_type}", method="GET")
    if not payload.get("ok"):
        raise MeetingAgentBridgeUnavailable(payload.get("detail") or "Meeting agent bridge health check failed")
    return payload


def run_bridge_action(body: dict) -> tuple[dict, int]:
    mode = bridge_mode()
    if mode != "http":
        raise MeetingAgentBridgeUnavailable("Meeting agent bridge is not configured")

    started = monotonic()
    payload = _request_json("meeting-agent/actions", method="POST", payload=body)
    latency_ms = int((monotonic() - started) * 1000)
    if not isinstance(payload, dict):
        raise MeetingAgentActionError("Meeting agent bridge returned an invalid payload")
    return payload, latency_ms
