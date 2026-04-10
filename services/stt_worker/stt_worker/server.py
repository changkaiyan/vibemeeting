import asyncio
import base64
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


def _decode_audio_chunk(data_base64: str) -> bytes:
    if not (data_base64 or "").strip():
        return b""
    return base64.b64decode(data_base64)


async def handle_realtime_connection(websocket, config: SttWorkerConfig) -> None:
    if websocket.request.path != DEFAULT_WS_PATH:
        await websocket.close(code=1008, reason="unsupported path")
        return

    state = WorkerConnectionState()
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
            await _send_json(
                websocket,
                {
                    "type": "session_started",
                    "speaker_name": state.speaker_name,
                    "speaker_identity": state.speaker_identity,
                    "provider": config.provider,
                },
            )
            continue

        if message_type == "audio_chunk":
            if state.session is None:
                await _send_error(websocket, "Session not started")
                continue
            try:
                delta = state.session.push_chunk(_decode_audio_chunk(payload.get("data_base64") or ""))
            except Exception as exc:
                await _send_error(websocket, str(exc))
                continue
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
                delta = state.session.finalize()
            except Exception as exc:
                await _send_error(websocket, str(exc))
                continue
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
