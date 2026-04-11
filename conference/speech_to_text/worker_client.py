import json

from conference.speech_to_text.exceptions import SpeechToTextError, SpeechToTextUnavailable


class WorkerRealtimeBridge:
    def __init__(self, url: str):
        self.url = (url or "").strip()
        self._connection = None

    async def connect(self) -> None:
        if not self.url:
            raise SpeechToTextUnavailable("Realtime STT worker is not configured")
        try:
            from websockets.asyncio.client import connect
        except ModuleNotFoundError as exc:
            raise SpeechToTextUnavailable("Realtime STT worker client dependency is not installed") from exc
        self._connection = await connect(self.url)

    async def close(self) -> None:
        if self._connection is not None:
            await self._connection.close()
            self._connection = None

    async def start_session(self, *, speaker_name: str = "", speaker_identity: str = "") -> dict:
        return await self._send_and_receive(
            {
                "type": "start",
                "speaker_name": speaker_name,
                "speaker_identity": speaker_identity,
            }
        )

    async def push_audio_chunk(self, *, mime_type: str = "", data_base64: str = "") -> dict:
        return await self._send_and_receive(
            {
                "type": "audio_chunk",
                "mime_type": mime_type,
                "data_base64": data_base64,
            }
        )

    async def stop_session(self) -> dict:
        return await self._send_and_receive({"type": "stop"})

    async def _send_and_receive(self, payload: dict) -> dict:
        if self._connection is None:
            raise SpeechToTextUnavailable("Realtime STT worker connection is not open")
        await self._connection.send(json.dumps(payload))
        raw_message = await self._connection.recv()
        if isinstance(raw_message, bytes):
            raw_message = raw_message.decode("utf-8")
        try:
            response = json.loads(raw_message)
        except json.JSONDecodeError as exc:
            raise SpeechToTextError("Realtime STT worker returned invalid JSON") from exc
        if (response.get("type") or "").strip().lower() == "error":
            raise SpeechToTextError(response.get("detail") or "Realtime STT worker request failed")
        return response
