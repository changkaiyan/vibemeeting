import gzip
import json
import uuid
from dataclasses import dataclass

from services.stt_worker.stt_worker.schemas import TranscriptDelta

OPENSPEECH_BIGMODEL_WS_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"

_PROTOCOL_VERSION = 0x1
_HEADER_SIZE_WORDS = 0x1
_HEADER_SIZE_BYTES = _HEADER_SIZE_WORDS * 4
_SERIALIZATION_JSON = 0x1
_SERIALIZATION_RAW = 0x0
_COMPRESSION_GZIP = 0x1
_COMPRESSION_NONE = 0x0
_MESSAGE_TYPE_FULL_CLIENT_REQUEST = 0x1
_MESSAGE_TYPE_AUDIO_ONLY_CLIENT_REQUEST = 0x2
_MESSAGE_TYPE_FULL_SERVER_RESPONSE = 0x9
_MESSAGE_TYPE_ERROR_RESPONSE = 0xF
_FLAG_NONE = 0x0
_FLAG_POSITIVE_SEQUENCE = 0x0
_FLAG_NEGATIVE_SEQUENCE = 0x3
_FLAG_LAST_AUDIO = 0x2


@dataclass
class _VolcengineStats:
    chunk_count: int = 0
    byte_count: int = 0


def _build_header(*, message_type: int, flags: int, serialization: int, compression: int) -> bytes:
    return bytes(
        [
            (_PROTOCOL_VERSION << 4) | _HEADER_SIZE_WORDS,
            ((message_type & 0x0F) << 4) | (flags & 0x0F),
            ((serialization & 0x0F) << 4) | (compression & 0x0F),
            0x00,
        ]
    )


def _decode_payload(*, serialization: int, compression: int, payload: bytes):
    body = payload or b""
    if compression == _COMPRESSION_GZIP:
        body = gzip.decompress(body)
    if serialization == _SERIALIZATION_JSON:
        return json.loads(body.decode("utf-8"))
    return body


def _extract_result_text(payload: dict) -> str:
    if not isinstance(payload, dict):
        return ""
    result = payload.get("result")
    if isinstance(result, list):
        parts = []
        for item in result:
            if isinstance(item, dict):
                text = (item.get("text") or "").strip()
                if text:
                    parts.append(text)
        if parts:
            return " ".join(parts).strip()
    if isinstance(result, dict):
        text = (result.get("text") or "").strip()
        if text:
            return text
    for key in ("text", "transcript", "utterance"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def build_openspeech_auth_headers(
    *,
    appid: str,
    access_token: str,
    resource_id: str,
    connect_id: str,
) -> dict[str, str]:
    normalized_appid = (appid or "").strip()
    normalized_token = (access_token or "").strip()
    normalized_resource = (resource_id or "").strip()
    normalized_connect = (connect_id or "").strip()
    if not normalized_appid:
        raise ValueError("Volcengine openspeech appid is required")
    if not normalized_token:
        raise ValueError("Volcengine openspeech access token is required")
    if not normalized_resource:
        raise ValueError("Volcengine openspeech resource id is required")
    if not normalized_connect:
        raise ValueError("Volcengine openspeech connect id is required")
    return {
        "X-Api-App-Key": normalized_appid,
        "X-Api-Access-Key": normalized_token,
        "X-Api-Resource-Id": normalized_resource,
        "X-Api-Connect-Id": normalized_connect,
    }


def build_openspeech_full_client_request_payload(
    *,
    resource_id: str,
    uid: str,
    reqid: str,
) -> dict:
    return {
        "user": {
            "uid": (uid or "anonymous").strip() or "anonymous",
        },
        "audio": {
            "format": "pcm",
            "rate": 16000,
            "bits": 16,
            "channel": 1,
            "language": "zh-CN",
        },
        "request": {
            "reqid": (reqid or "").strip(),
            "resource_id": (resource_id or "").strip(),
            "model_name": "bigmodel",
            "enable_itn": False,
            "enable_ddc": False,
            "enable_punc": False,
        },
    }


def build_full_client_request_frame(payload: dict) -> bytes:
    body = gzip.compress(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
    return (
        _build_header(
            message_type=_MESSAGE_TYPE_FULL_CLIENT_REQUEST,
            flags=_FLAG_NONE,
            serialization=_SERIALIZATION_JSON,
            compression=_COMPRESSION_GZIP,
        )
        + len(body).to_bytes(4, "big")
        + body
    )


def build_audio_only_request_frame(payload: bytes, *, is_last: bool) -> bytes:
    body = gzip.compress(payload or b"")
    flags = _FLAG_LAST_AUDIO if is_last else _FLAG_POSITIVE_SEQUENCE
    return (
        _build_header(
            message_type=_MESSAGE_TYPE_AUDIO_ONLY_CLIENT_REQUEST,
            flags=flags,
            serialization=_SERIALIZATION_RAW,
            compression=_COMPRESSION_GZIP,
        )
        + len(body).to_bytes(4, "big")
        + body
    )


def parse_server_message(message: bytes | str) -> dict:
    if isinstance(message, str):
        try:
            return {
                "message_type": None,
                "flags": None,
                "payload": json.loads(message),
            }
        except json.JSONDecodeError:
            return {
                "message_type": None,
                "flags": None,
                "payload": {"text": message},
            }
    if not isinstance(message, (bytes, bytearray)) or len(message) < _HEADER_SIZE_BYTES:
        raise ValueError("Invalid openspeech server message")
    raw = bytes(message)
    version = raw[0] >> 4
    if version != _PROTOCOL_VERSION:
        raise ValueError(f"Unsupported openspeech protocol version: {version}")
    header_size = (raw[0] & 0x0F) * 4
    message_type = raw[1] >> 4
    flags = raw[1] & 0x0F
    serialization = raw[2] >> 4
    compression = raw[2] & 0x0F
    offset = header_size
    parsed = {
        "message_type": message_type,
        "flags": flags,
        "serialization": serialization,
        "compression": compression,
    }
    if message_type == _MESSAGE_TYPE_FULL_SERVER_RESPONSE:
        parsed["sequence"] = int.from_bytes(raw[offset : offset + 4], "big", signed=True)
        offset += 4
        payload_size = int.from_bytes(raw[offset : offset + 4], "big")
        offset += 4
        parsed["payload"] = _decode_payload(
            serialization=serialization,
            compression=compression,
            payload=raw[offset : offset + payload_size],
        )
        return parsed
    if message_type == _MESSAGE_TYPE_ERROR_RESPONSE:
        parsed["error_code"] = int.from_bytes(raw[offset : offset + 4], "big")
        offset += 4
        payload_size = int.from_bytes(raw[offset : offset + 4], "big")
        offset += 4
        parsed["payload"] = _decode_payload(
            serialization=serialization,
            compression=compression,
            payload=raw[offset : offset + payload_size],
        )
        return parsed
    payload_size = int.from_bytes(raw[offset : offset + 4], "big")
    offset += 4
    parsed["payload"] = _decode_payload(
        serialization=serialization,
        compression=compression,
        payload=raw[offset : offset + payload_size],
    )
    return parsed


class VolcengineRealtimeProvider:
    def __init__(
        self,
        *,
        appid: str,
        access_token: str,
        resource_id: str,
        ws_url: str = OPENSPEECH_BIGMODEL_WS_URL,
        speaker_name: str = "",
        speaker_identity: str = "",
    ):
        self.appid = (appid or "").strip()
        self.access_token = (access_token or "").strip()
        self.resource_id = (resource_id or "").strip()
        if not self.appid:
            raise ValueError("Volcengine openspeech appid is required")
        if not self.access_token:
            raise ValueError("Volcengine openspeech access token is required")
        if not self.resource_id:
            raise ValueError("Volcengine openspeech resource id is required")
        self.ws_url = (ws_url or OPENSPEECH_BIGMODEL_WS_URL).strip() or OPENSPEECH_BIGMODEL_WS_URL
        self.speaker_name = (speaker_name or "").strip()
        self.speaker_identity = (speaker_identity or "").strip()
        self._connect_id = str(uuid.uuid4())
        self._connection = None
        self._stats = _VolcengineStats()
        self._connector = None
        self._last_partial_text = ""

    async def start_session(self) -> dict:
        if self._connection is None:
            self._connection = await self._connect()
        uid = self.speaker_identity or self.speaker_name or "anonymous"
        reqid = str(uuid.uuid4())
        payload = build_openspeech_full_client_request_payload(
            resource_id=self.resource_id,
            uid=uid,
            reqid=reqid,
        )
        await self._connection.send(build_full_client_request_frame(payload))
        return {
            "type": "session_started",
            "speaker_name": self.speaker_name,
            "speaker_identity": self.speaker_identity,
            "provider": "volcengine_realtime",
        }

    async def push_chunk(self, payload: bytes, *, mime_type: str = "") -> TranscriptDelta:
        if self._connection is None:
            raise RuntimeError("Volcengine realtime session is not started")
        raw = payload or b""
        self._stats.chunk_count += 1
        self._stats.byte_count += len(raw)
        await self._connection.send(
            build_audio_only_request_frame(
                raw,
                is_last=False,
            )
        )
        text = await self._receive_transcript_text(default=self._last_partial_text)
        self._last_partial_text = text or self._last_partial_text
        return TranscriptDelta(
            message_type="partial_transcript",
            text=text,
            chunk_count=self._stats.chunk_count,
            byte_count=self._stats.byte_count,
        )

    async def finalize(self) -> TranscriptDelta:
        if self._connection is None:
            raise RuntimeError("Volcengine realtime session is not started")
        try:
            await self._connection.send(
                build_audio_only_request_frame(
                    b"",
                    is_last=True,
                )
            )
            text = await self._receive_transcript_text(default=self._last_partial_text)
            return TranscriptDelta(
                message_type="final_transcript",
                text=text,
                chunk_count=self._stats.chunk_count,
                byte_count=self._stats.byte_count,
            )
        finally:
            await self.close()

    async def close(self) -> None:
        if self._connection is not None:
            await self._connection.close()
            self._connection = None

    async def decode_partial(self, audio_window: bytes | None = None) -> str:
        return self._last_partial_text

    async def _connect(self):
        connector = self._connector
        if connector is None:
            try:
                from websockets.asyncio.client import connect
            except ModuleNotFoundError as exc:
                raise RuntimeError("websockets client dependency is not installed") from exc
            connector = connect
        return await connector(
            self.ws_url,
            additional_headers=build_openspeech_auth_headers(
                appid=self.appid,
                access_token=self.access_token,
                resource_id=self.resource_id,
                connect_id=self._connect_id,
            ),
        )

    async def _receive_transcript_text(self, *, default: str = "") -> str:
        message = await self._connection.recv()
        parsed = parse_server_message(message)
        if parsed["message_type"] == _MESSAGE_TYPE_ERROR_RESPONSE:
            payload = parsed.get("payload") or {}
            detail = ""
            if isinstance(payload, dict):
                detail = (payload.get("error") or payload.get("message") or "").strip()
            if not detail:
                detail = f"Volcengine error code {parsed.get('error_code')}"
            raise RuntimeError(detail)
        payload = parsed.get("payload") or {}
        text = _extract_result_text(payload)
        return text or default
