import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from services.meeting_agent_bridge.config import load_config
from services.meeting_agent_bridge.runner import health_payload, run_action


class MeetingAgentBridgeHandler(BaseHTTPRequestHandler):
    server_version = "MeetingAgentBridge/0.1"

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.rstrip("/") == "/health":
            params = parse_qs(parsed.query)
            agent_type = ((params.get("agent_type") or [""])[0] or "").strip()
            payload = health_payload(agent_type, self.server.bridge_config)
            self._send_json(HTTPStatus.OK if payload.get("ok") else HTTPStatus.SERVICE_UNAVAILABLE, payload)
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"detail": "Not found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.rstrip("/") != "/meeting-agent/actions":
            self._send_json(HTTPStatus.NOT_FOUND, {"detail": "Not found"})
            return
        try:
            body = self._read_json_body()
        except ValueError as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"detail": str(exc)})
            return

        try:
            payload = run_action(body, self.server.bridge_config)
        except Exception as exc:
            self._send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"detail": str(exc)})
            return
        self._send_json(HTTPStatus.OK, payload)

    def log_message(self, fmt: str, *args) -> None:
        print(
            f'{self.address_string()} - - [{self.log_date_time_string()}] {fmt % args}',
            flush=True,
        )

    def _read_json_body(self) -> dict:
        content_length = int(self.headers.get("Content-Length", "0") or "0")
        raw_body = self.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise ValueError("JSON body must be an object")
        return payload

    def _send_json(self, status_code: HTTPStatus, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(int(status_code))
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class MeetingAgentBridgeHttpServer(ThreadingHTTPServer):
    def __init__(self, server_address, handler_class, bridge_config):
        super().__init__(server_address, handler_class)
        self.bridge_config = bridge_config


def main() -> None:
    config = load_config()
    server = MeetingAgentBridgeHttpServer(
        (config.host, config.port),
        MeetingAgentBridgeHandler,
        config,
    )
    print(
        "meeting-agent-bridge listening on "
        f"http://{config.host}:{config.port} workspace={config.workspace_root} "
        f"codex_bin={config.codex_bin} model={config.codex_model or '-'}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
