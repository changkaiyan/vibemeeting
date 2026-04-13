import asyncio
import base64
import inspect
import json
from dataclasses import dataclass

from websockets.asyncio.server import serve

from services.stt_worker.stt_worker.config import SttWorkerConfig, load_config
from services.stt_worker.stt_worker.pipeline.stream_session import build_realtime_session

DEFAULT_WS_PATH = "/ws/realtime-transcribe"


@dataclass
class WorkerConnectionState:
    speaker_name: str = ""
    speaker_identity: str = ""
    session: object | None = None


async def _send_json(websocket, payload: dict) -> None:
    await websocket.send(json.dumps(payload))


async def _send_error(websocket, detail: str) -> None:
    await _send_json(websocket, {"type": "error", "detail": detail})


async def _maybe_await(value):
    if inspect.isawaitable(value):
        return await value
    return value


def _decode_audio_chunk(data_base64: str) -> bytes:
    if not (data_base64 or "").strip():
        return b""
    return base64.b64decode(data_base64)


async def handle_realtime_connection(websocket, config: SttWorkerConfig) -> None:
    if websocket.request.path != DEFAULT_WS_PATH:
        await websocket.close(code=1008, reason="unsupported path")
        return

    state = WorkerConnectionState()
    print(
        f"stt-worker connection opened path={websocket.request.path} provider={config.provider}",
        flush=True,
    )
    async for raw_message in websocket:
        try:
            payload = json.loads(raw_message)
        except json.JSONDecodeError:
            await _send_error(websocket, "Invalid JSON")
            continue

        message_type = (payload.get("type") or "").strip().lower()
        if message_type == "start":
            state.speaker_name = (payload.get("speaker_name") or "").strip()[:80]
            state.speaker_identity = (payload.get("speaker_identity") or "").strip()[:120]
            try:
                state.session = build_realtime_session(
                    config,
                    speaker_name=state.speaker_name,
                    speaker_identity=state.speaker_identity,
                )
            except Exception as exc:
                state.session = None
                await _send_error(websocket, str(exc))
                continue
            session_started_payload = {
                "type": "session_started",
                "speaker_name": state.speaker_name,
                "speaker_identity": state.speaker_identity,
                "provider": config.provider,
            }
            if hasattr(state.session, "start_session"):
                try:
                    session_started_payload = await _maybe_await(state.session.start_session())
                except Exception as exc:
                    state.session = None
                    await _send_error(websocket, str(exc))
                    continue
            await _send_json(websocket, session_started_payload)
            print(
                "stt-worker session started "
                f"speaker_name={state.speaker_name or '-'} "
                f"speaker_identity={state.speaker_identity or '-'} "
                f"provider={config.provider}",
                flush=True,
            )
            continue

        if message_type == "audio_chunk":
            if state.session is None:
                await _send_error(websocket, "Session not started")
                continue
            raw = _decode_audio_chunk(payload.get("data_base64") or "")
            mime_type = (payload.get("mime_type") or "").strip()
            try:
                delta = await _maybe_await(state.session.push_chunk(
                    raw,
                    mime_type=mime_type,
                ))
            except Exception as exc:
                await _send_error(websocket, str(exc))
                continue
            print(
                "stt-worker audio chunk "
                f"mime={mime_type or '-'} "
                f"payload_bytes={len(raw)} "
                f"chunk_count={delta.chunk_count} "
                f"byte_count={delta.byte_count}",
                flush=True,
            )
            await _send_json(
                websocket,
                {
                    "type": delta.message_type,
                    "text": delta.text,
                    "chunk_count": delta.chunk_count,
                    "byte_count": delta.byte_count,
                },
            )
            continue

        if message_type == "stop":
            if state.session is None:
                await _send_error(websocket, "Session not started")
                continue
            try:
                delta = await _maybe_await(state.session.finalize())
            except Exception as exc:
                await _send_error(websocket, str(exc))
                continue
            print(
                "stt-worker session finalized "
                f"chunk_count={delta.chunk_count} "
                f"byte_count={delta.byte_count} "
                f"text={delta.text!r}",
                flush=True,
            )
            await _send_json(
                websocket,
                {
                    "type": delta.message_type,
                    "text": delta.text,
                    "chunk_count": delta.chunk_count,
                    "byte_count": delta.byte_count,
                    "speaker_name": state.speaker_name,
                    "speaker_identity": state.speaker_identity,
                },
            )
            state = WorkerConnectionState()
            continue

        await _send_error(websocket, f"Unsupported message type: {message_type or 'unknown'}")

    print("stt-worker connection closed", flush=True)


async def start_server(config: SttWorkerConfig):
    return await serve(
        lambda websocket: handle_realtime_connection(websocket, config),
        config.host,
        config.port,
    )


def main():
    config = load_config()
    async def runner():
        async with await start_server(config):
            print(
                f"stt-worker listening on ws://{config.host}:{config.port}{DEFAULT_WS_PATH} "
                f"provider={config.provider} model={config.model_size} compute={config.compute_type} "
                f"language={config.language}",
                flush=True,
            )
            await asyncio.Future()

    asyncio.run(runner())


if __name__ == "__main__":
    main()
