import asyncio
import json
import re
import threading
import time
from types import SimpleNamespace
from urllib.parse import parse_qs
from uuid import uuid4

from asgiref.sync import sync_to_async
from django.contrib.auth.models import User
from django.db import close_old_connections
from rest_framework_simplejwt.authentication import JWTAuthentication
from rest_framework_simplejwt.exceptions import InvalidToken, TokenError

from conference.meeting_refs import meeting_from_ref
from conference.models import Meeting, MeetingMessage, RealtimeBotProvider
from conference.serializers import MeetingMessageSerializer
from conference.utils import can_moderate, has_meeting_access, meeting_membership
from conference import views as meeting_views

_PATH_ID_RE = re.compile(r"^/ws/meetings/(?P<meeting_id>\d+)/ai-controls/realtime-audio/?$")
_PATH_REF_RE = re.compile(r"^/ws/my/meetings/(?P<meeting_ref>[^/]+)/ai-controls/realtime-audio/?$")


def _extract_token(scope) -> str:
    params = parse_qs((scope.get("query_string") or b"").decode("utf-8"))
    values = params.get("token") or []
    return values[0].strip() if values else ""


@sync_to_async
def _authenticate_websocket_user(token: str) -> User | None:
    if not token:
        return None
    auth = JWTAuthentication()
    try:
        validated = auth.get_validated_token(token)
    except (InvalidToken, TokenError):
        return None
    return auth.get_user(validated)


@sync_to_async
def _meeting_for_scope(scope, user: User) -> Meeting | None:
    path = scope.get("path", "")
    match = _PATH_ID_RE.match(path)
    if match:
        meeting = Meeting.objects.filter(id=int(match.group("meeting_id"))).first()
        if meeting and has_meeting_access(user, meeting):
            return meeting
        return None

    match = _PATH_REF_RE.match(path)
    if match:
        return meeting_from_ref(user, match.group("meeting_ref"))
    return None


@sync_to_async
def _can_moderate_meeting(user: User, meeting: Meeting) -> bool:
    actor_membership = meeting_membership(meeting.id, user.id)
    return bool(can_moderate(user, actor_membership))


@sync_to_async
def _meeting_ready_payload(meeting: Meeting) -> dict:
    provider = meeting_views._meeting_realtime_bot_provider(meeting)
    return {
        "meeting_id": meeting.id,
        "provider": provider,
        "streaming": provider == "volcengine",
        "ready": bool(meeting_views._meeting_realtime_bot_ready(meeting)),
    }


@sync_to_async
def _invoke_audio_ingress(user: User, meeting: Meeting, payload: dict, client_ip: str) -> tuple[int, dict | None]:
    fake_request = SimpleNamespace(
        user=user,
        data=payload,
        META={"REMOTE_ADDR": client_ip},
    )
    response = meeting_views._meeting_ai_audio_ingress_impl(
        fake_request,
        meeting,
        int(meeting.id),
    )
    status_code = int(getattr(response, "status_code", 500) or 500)
    body = getattr(response, "data", None)
    return status_code, body if isinstance(body, dict) else None


async def _send_json(send, payload: dict) -> None:
    await send({"type": "websocket.send", "text": json.dumps(payload)})


def _client_ip(scope) -> str:
    client = scope.get("client")
    if isinstance(client, (list, tuple)) and client:
        return str(client[0])
    return "unknown"


class _VolcengineRealtimeStreamBridge:
    def __init__(self, *, meeting: Meeting, emit):
        self.meeting = meeting
        self.emit = emit
        self._ws = None
        self._websocket_module = None
        self._send_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._receiver_thread: threading.Thread | None = None
        self._session_id = str(uuid4())
        self._connect_id = str(uuid4())

        self._request_audio = not bool(getattr(meeting, "realtime_bot_muted", False))
        self._turn_active = False
        self._turn_text_done = False
        self._turn_audio_done = not self._request_audio
        self._turn_text_chunks: list[str] = []
        self._turn_audio_pcm_bytes = bytearray()
        self._turn_ack_audio_chunks = 0
        self._turn_usage: dict[str, int] = {}
        self._turn_asr_final_chunks: list[str] = []
        self._turn_asr_latest_interim = ""
        self._turn_started_at = 0.0
        self._turn_text_done_at = 0.0
        self._turn_last_text_at = 0.0
        self._turn_last_audio_at = 0.0
        self._turn_asr_done_at = 0.0
        self._turn_fallback_attempted = False

    def start(self) -> None:
        close_old_connections()
        try:
            import websocket  # type: ignore
        except Exception as exc:
            raise RuntimeError("websocket client library is not available") from exc

        ws_url = meeting_views._normalized_realtime_volc_ws_url(
            getattr(self.meeting, "realtime_bot_volc_ws_url", "")
        )
        app_id = meeting_views._meeting_realtime_bot_volc_app_id(self.meeting)
        app_key = meeting_views._meeting_realtime_bot_volc_app_key(self.meeting)
        access_key = meeting_views._meeting_realtime_bot_volc_access_key(self.meeting)
        resource_id = meeting_views._normalized_realtime_volc_resource_id(
            getattr(self.meeting, "realtime_bot_volc_resource_id", "")
        )
        uid = meeting_views._meeting_realtime_bot_volc_uid(self.meeting)
        dialog_model = meeting_views._meeting_realtime_bot_volc_model(self.meeting)
        speaker = meeting_views._meeting_realtime_bot_volc_speaker(self.meeting, dialog_model=dialog_model)

        if not app_id:
            raise RuntimeError("Volcengine App ID is empty")
        if not access_key:
            raise RuntimeError("Volcengine Access Key is empty")
        if not resource_id:
            raise RuntimeError("Volcengine Resource ID is empty")

        headers = meeting_views._volcengine_ws_headers(
            app_id=app_id,
            app_key=app_key,
            access_key=access_key,
            resource_id=resource_id,
            connect_id=self._connect_id,
        )
        ws = websocket.create_connection(
            ws_url,
            header=headers,
            timeout=meeting_views._REALTIME_BOT_WS_CONNECT_TIMEOUT_SECONDS,
        )
        if hasattr(ws, "settimeout"):
            ws.settimeout(1)
        self._ws = ws
        self._websocket_module = websocket

        start_connection_payload = {}
        meeting_views._volcengine_debug_emit(
            direction="out",
            phase="send",
            event=meeting_views._VOLCENGINE_EVENT_START_CONNECTION,
            payload=start_connection_payload,
        )
        self._send_binary(
            meeting_views._volcengine_build_request(
                event=meeting_views._VOLCENGINE_EVENT_START_CONNECTION,
                payload=start_connection_payload,
            )
        )
        meeting_views._volcengine_wait_for_event(
            ws=ws,
            websocket_module=websocket,
            expected_event=meeting_views._VOLCENGINE_EVENT_CONNECTION_STARTED,
            operation="start_connection",
            timeout_seconds=meeting_views._REALTIME_BOT_WS_CONNECT_TIMEOUT_SECONDS,
        )

        tts_payload = {
            "audio_config": {
                "channel": 1,
                "format": "pcm",
                "sample_rate": 24000,
            }
        }
        if (speaker or "").strip():
            tts_payload["speaker"] = speaker.strip()

        start_session_payload = {
            "asr": {
                "audio_config": {
                    "channel": 1,
                    "format": "pcm",
                    "sample_rate": 16000,
                },
                "extra": {
                    "end_smooth_window_ms": 1800,
                    "enable_asr_twopass": True,
                },
            },
            "tts": tts_payload,
            "dialog": {
                "bot_name": meeting_views._meeting_realtime_bot_display_name(self.meeting),
                "dialog_id": self._session_id,
                "extra": {
                    "strict_audit": True,
                    "recv_timeout": meeting_views._REALTIME_BOT_RESPONSE_TIMEOUT_SECONDS,
                    "input_mod": "push_to_talk",
                    "model": dialog_model,
                },
            },
            "user": {"uid": uid},
        }
        meeting_views._volcengine_debug_emit(
            direction="out",
            phase="send",
            event=meeting_views._VOLCENGINE_EVENT_START_SESSION,
            session_id=self._session_id,
            payload=start_session_payload,
        )
        self._send_binary(
            meeting_views._volcengine_build_request(
                event=meeting_views._VOLCENGINE_EVENT_START_SESSION,
                session_id=self._session_id,
                payload=start_session_payload,
            )
        )
        meeting_views._volcengine_wait_for_event(
            ws=ws,
            websocket_module=websocket,
            expected_event=meeting_views._VOLCENGINE_EVENT_SESSION_STARTED,
            operation="start_session",
            timeout_seconds=meeting_views._REALTIME_BOT_WS_CONNECT_TIMEOUT_SECONDS,
            session_id=self._session_id,
        )

        self._receiver_thread = threading.Thread(
            target=self._recv_loop,
            name=f"volc-bridge-{self._session_id}",
            daemon=True,
        )
        self._receiver_thread.start()

    def close(self) -> None:
        self._stop_event.set()
        self._safe_send_request(meeting_views._VOLCENGINE_EVENT_FINISH_SESSION, {})
        self._safe_send_request(meeting_views._VOLCENGINE_EVENT_FINISH_CONNECTION, {})
        ws = self._ws
        self._ws = None
        if ws is not None:
            try:
                ws.close()
            except Exception:
                pass
        self._finalize_turn_if_needed()

    def start_turn(self) -> None:
        had_active = False
        with self._state_lock:
            had_active = self._turn_active
            self._turn_active = True
            self._turn_text_done = False
            self._turn_audio_done = not self._request_audio
            self._turn_text_chunks = []
            self._turn_audio_pcm_bytes = bytearray()
            self._turn_ack_audio_chunks = 0
            self._turn_usage = {}
            self._turn_asr_final_chunks = []
            self._turn_asr_latest_interim = ""
            self._turn_started_at = time.time()
            self._turn_text_done_at = 0.0
            self._turn_last_text_at = 0.0
            self._turn_last_audio_at = 0.0
            self._turn_asr_done_at = 0.0
            self._turn_fallback_attempted = False
        if had_active:
            self._safe_send_request(meeting_views._VOLCENGINE_EVENT_CLIENT_INTERRUPT, {})

    def send_audio_pcm16(self, audio_pcm16: bytes) -> None:
        if not audio_pcm16:
            return
        with self._state_lock:
            if not self._turn_active:
                self._turn_active = True
        chunk_size = 640
        for offset in range(0, len(audio_pcm16), chunk_size):
            chunk = audio_pcm16[offset : offset + chunk_size]
            if not chunk:
                continue
            meeting_views._volcengine_debug_emit(
                direction="out",
                phase="send_audio",
                event=meeting_views._VOLCENGINE_EVENT_AUDIO_REQUEST,
                session_id=self._session_id,
                extra={"audio_bytes": len(chunk)},
            )
            self._send_binary(
                meeting_views._volcengine_build_audio_request(
                    event=meeting_views._VOLCENGINE_EVENT_AUDIO_REQUEST,
                    session_id=self._session_id,
                    audio_payload=chunk,
                )
            )

    def end_turn(self) -> None:
        self._safe_send_request(meeting_views._VOLCENGINE_EVENT_END_ASR, {})

    def _safe_send_request(self, event: int, payload: dict) -> None:
        try:
            meeting_views._volcengine_debug_emit(
                direction="out",
                phase="send",
                event=event,
                session_id=self._session_id,
                payload=payload,
            )
            self._send_binary(
                meeting_views._volcengine_build_request(
                    event=event,
                    session_id=self._session_id if event >= 100 else None,
                    payload=payload,
                )
            )
        except Exception:
            pass

    def _send_binary(self, payload: bytes) -> None:
        ws = self._ws
        if ws is None:
            raise RuntimeError("volcengine websocket is closed")
        with self._send_lock:
            ws.send_binary(payload)

    def _recv_loop(self) -> None:
        close_old_connections()
        ws = self._ws
        websocket_module = self._websocket_module
        if ws is None or websocket_module is None:
            return
        timeout_error = getattr(websocket_module, "WebSocketTimeoutException", Exception)
        while not self._stop_event.is_set():
            try:
                raw = ws.recv()
            except timeout_error:
                self._advance_turn_state_on_timeout()
                self._finalize_turn_if_needed()
                continue
            except Exception as exc:
                if not self._stop_event.is_set():
                    self._emit_error(str(exc))
                break
            if not raw:
                continue
            event = meeting_views._volcengine_parse_ws_response(raw)
            if event is None:
                continue
            event_code = int(event.get("event") or 0)
            event_name = str(event.get("event_name") or "").strip().lower()
            payload_msg = event.get("payload_msg")
            message_type = str(event.get("message_type") or "").strip().upper()

            meeting_views._volcengine_debug_emit(
                direction="in",
                phase="recv",
                event=event_code if event_code > 0 else None,
                event_name=event_name,
                session_id=str(event.get("session_id") or self._session_id),
                payload=payload_msg,
                extra={
                    "message_type": message_type,
                    "payload_size": int(event.get("payload_size") or 0),
                    "code": event.get("code"),
                },
            )

            try:
                meeting_views._volcengine_raise_if_error_event(event)
            except Exception as exc:
                self._emit_error(str(exc))
                continue

            if event_code == 154 and isinstance(payload_msg, dict):
                usage = payload_msg.get("usage")
                if isinstance(usage, dict):
                    with self._state_lock:
                        self._turn_usage = {
                            "input_audio_tokens": int(usage.get("input_audio_tokens") or 0),
                            "input_text_tokens": int(usage.get("input_text_tokens") or 0),
                            "output_text_tokens": int(usage.get("output_text_tokens") or 0),
                            "output_audio_tokens": int(usage.get("output_audio_tokens") or 0),
                        }
                continue

            if event_code == meeting_views._VOLCENGINE_EVENT_ASR_RESPONSE:
                asr_text, is_interim = meeting_views._extract_asr_text_from_volcengine_payload(payload_msg)
                if asr_text:
                    with self._state_lock:
                        if is_interim:
                            self._turn_asr_latest_interim = asr_text
                        elif not self._turn_asr_final_chunks or asr_text != self._turn_asr_final_chunks[-1]:
                            self._turn_asr_final_chunks.append(asr_text)
                    self._emit({"type": "asr", "text": asr_text, "is_interim": bool(is_interim)})
                continue

            if event_code == meeting_views._VOLCENGINE_EVENT_ASR_DONE:
                no_content = False
                if isinstance(payload_msg, dict):
                    no_content = bool(payload_msg.get("no_content"))
                if no_content:
                    with self._state_lock:
                        self._turn_active = False
                        self._turn_text_done = False
                        self._turn_audio_done = not self._request_audio
                        self._turn_text_chunks = []
                        self._turn_audio_pcm_bytes = bytearray()
                        self._turn_ack_audio_chunks = 0
                        self._turn_usage = {}
                        self._turn_asr_final_chunks = []
                        self._turn_asr_latest_interim = ""
                        self._turn_started_at = 0.0
                        self._turn_text_done_at = 0.0
                        self._turn_last_text_at = 0.0
                        self._turn_last_audio_at = 0.0
                        self._turn_asr_done_at = 0.0
                        self._turn_fallback_attempted = False
                    self._emit({"type": "no_content", "detail": "asr no content"})
                else:
                    with self._state_lock:
                        self._turn_asr_done_at = time.time()
                continue

            with self._state_lock:
                if not self._turn_active and event_code in {
                    meeting_views._VOLCENGINE_EVENT_TEXT_DELTA,
                    meeting_views._VOLCENGINE_EVENT_TEXT_DONE,
                    meeting_views._VOLCENGINE_EVENT_TTS_AUDIO,
                    meeting_views._VOLCENGINE_EVENT_TTS_DONE,
                }:
                    self._turn_active = True
                    self._turn_text_done = False
                    self._turn_audio_done = not self._request_audio
                    self._turn_started_at = self._turn_started_at or time.time()

            if self._request_audio and message_type == "SERVER_ACK":
                audio_chunk = meeting_views._volcengine_extract_tts_pcm16_bytes(payload_msg)
                if audio_chunk:
                    with self._state_lock:
                        self._turn_audio_pcm_bytes.extend(audio_chunk)
                        self._turn_ack_audio_chunks += 1
                        self._turn_last_audio_at = time.time()

            if event_code == meeting_views._VOLCENGINE_EVENT_TEXT_DELTA:
                chunk_text = meeting_views._extract_text_from_volcengine_ws_event(
                    payload_msg if payload_msg is not None else event
                )
                if chunk_text:
                    with self._state_lock:
                        if not self._turn_text_chunks or chunk_text != self._turn_text_chunks[-1]:
                            self._turn_text_chunks.append(chunk_text)
                            self._turn_last_text_at = time.time()
                    self._emit({"type": "reply_delta", "content": chunk_text})
            elif event_code == meeting_views._VOLCENGINE_EVENT_TEXT_DONE:
                with self._state_lock:
                    self._turn_text_done = True
                    self._turn_text_done_at = time.time()
            elif event_code == meeting_views._VOLCENGINE_EVENT_TTS_AUDIO and self._request_audio:
                audio_chunk = meeting_views._volcengine_extract_tts_pcm16_bytes(payload_msg)
                if audio_chunk:
                    with self._state_lock:
                        if self._turn_ack_audio_chunks == 0:
                            self._turn_audio_pcm_bytes.extend(audio_chunk)
                        self._turn_last_audio_at = time.time()
            elif event_code == meeting_views._VOLCENGINE_EVENT_TTS_DONE:
                with self._state_lock:
                    self._turn_audio_done = True
                    self._turn_last_audio_at = time.time()

            if event_name in {"chatended", "chat_ended", "response.done", "response.completed"}:
                with self._state_lock:
                    self._turn_text_done = True
                    if self._turn_text_done_at <= 0:
                        self._turn_text_done_at = time.time()

            self._advance_turn_state_on_timeout()
            self._finalize_turn_if_needed()

    def _advance_turn_state_on_timeout(self) -> None:
        emit_no_content = False
        fallback_prompt = ""
        forced_text_done = False
        now = time.time()
        with self._state_lock:
            if not self._turn_active:
                return
            if self._turn_text_chunks and not self._turn_text_done:
                last_text_at = self._turn_last_text_at or self._turn_started_at or now
                if now - last_text_at >= 1.2:
                    self._turn_text_done = True
                    if self._turn_text_done_at <= 0:
                        self._turn_text_done_at = now
                    forced_text_done = True
            if self._request_audio and self._turn_text_done and not self._turn_audio_done:
                text_done_at = self._turn_text_done_at or self._turn_started_at or now
                text_wait = now - text_done_at
                if self._turn_audio_pcm_bytes:
                    last_audio_at = self._turn_last_audio_at or text_done_at
                    if now - last_audio_at >= 0.8:
                        self._turn_audio_done = True
                elif text_wait >= 1.6:
                    self._turn_audio_done = True

            if self._turn_asr_done_at > 0 and not self._turn_text_chunks and not self._turn_audio_pcm_bytes:
                asr_wait = now - self._turn_asr_done_at
                recognized_text = "".join(
                    part for part in self._turn_asr_final_chunks if str(part).strip()
                ).strip()
                if not recognized_text:
                    recognized_text = str(self._turn_asr_latest_interim or "").strip()

                if recognized_text and not self._turn_fallback_attempted and asr_wait >= 1.6:
                    self._turn_fallback_attempted = True
                    fallback_prompt = recognized_text
                elif asr_wait >= 4.5:
                    self._turn_active = False
                    self._turn_text_done = False
                    self._turn_audio_done = not self._request_audio
                    self._turn_text_chunks = []
                    self._turn_audio_pcm_bytes = bytearray()
                    self._turn_ack_audio_chunks = 0
                    self._turn_usage = {}
                    self._turn_asr_final_chunks = []
                    self._turn_asr_latest_interim = ""
                    self._turn_started_at = 0.0
                    self._turn_text_done_at = 0.0
                    self._turn_last_text_at = 0.0
                    self._turn_last_audio_at = 0.0
                    self._turn_asr_done_at = 0.0
                    self._turn_fallback_attempted = False
                    emit_no_content = True
        if forced_text_done:
            meeting_views._volcengine_debug_emit(
                direction="internal",
                phase="turn_timeout_force_text_done",
                session_id=self._session_id,
            )
        if fallback_prompt:
            try:
                fallback_text, fallback_audio_base64, fallback_audio_mime = meeting_views._call_realtime_bot_via_volcengine_websocket(
                    meeting=self.meeting,
                    prompt=fallback_prompt,
                    request_audio=self._request_audio,
                )
                fallback_text = str(fallback_text or "").strip()
                if fallback_text:
                    self._emit_result_message(
                        text=fallback_text,
                        audio_base64=(fallback_audio_base64 or "").strip(),
                        audio_mime=(fallback_audio_mime or "").strip(),
                        recognized_text=fallback_prompt,
                        usage=None,
                    )
                    with self._state_lock:
                        self._turn_active = False
                        self._turn_text_done = False
                        self._turn_audio_done = not self._request_audio
                        self._turn_text_chunks = []
                        self._turn_audio_pcm_bytes = bytearray()
                        self._turn_ack_audio_chunks = 0
                        self._turn_usage = {}
                        self._turn_asr_final_chunks = []
                        self._turn_asr_latest_interim = ""
                        self._turn_started_at = 0.0
                        self._turn_text_done_at = 0.0
                        self._turn_last_text_at = 0.0
                        self._turn_last_audio_at = 0.0
                        self._turn_asr_done_at = 0.0
                        self._turn_fallback_attempted = False
                    return
            except Exception:
                pass
        if emit_no_content:
            self._emit({"type": "no_content", "detail": "asr no content timeout"})

    def _finalize_turn_if_needed(self) -> None:
        with self._state_lock:
            if not self._turn_active:
                return
            can_finalize = bool(self._turn_audio_done and (self._turn_text_done or self._turn_audio_pcm_bytes))
            if not can_finalize:
                return
            text_chunks = list(self._turn_text_chunks)
            audio_bytes = bytes(self._turn_audio_pcm_bytes)
            usage = dict(self._turn_usage)
            asr_final_chunks = list(self._turn_asr_final_chunks)
            asr_latest_interim = str(self._turn_asr_latest_interim or "")
            self._turn_active = False
            self._turn_text_done = False
            self._turn_audio_done = not self._request_audio
            self._turn_text_chunks = []
            self._turn_audio_pcm_bytes = bytearray()
            self._turn_ack_audio_chunks = 0
            self._turn_usage = {}
            self._turn_asr_final_chunks = []
            self._turn_asr_latest_interim = ""
            self._turn_started_at = 0.0
            self._turn_text_done_at = 0.0
            self._turn_last_text_at = 0.0
            self._turn_last_audio_at = 0.0
            self._turn_asr_done_at = 0.0
            self._turn_fallback_attempted = False

        text = "".join(part for part in text_chunks if part.strip()).strip()
        recognized_text = "".join(part for part in asr_final_chunks if part.strip()).strip()
        if not recognized_text:
            recognized_text = asr_latest_interim.strip()
        audio_base64 = ""
        audio_mime = ""
        if self._request_audio and audio_bytes:
            audio_base64 = meeting_views._pcm16le_to_wav_base64(audio_bytes, sample_rate=24000, channels=1)
            if audio_base64:
                audio_mime = "audio/wav"
        text = meeting_views._normalized_realtime_reply_text(text, audio_base64=audio_base64)
        if not text:
            return
        self._emit_result_message(
            text=text,
            audio_base64=audio_base64,
            audio_mime=audio_mime,
            recognized_text=recognized_text,
            usage=usage,
        )

    def _emit_result_message(
        self,
        *,
        text: str,
        audio_base64: str,
        audio_mime: str,
        recognized_text: str,
        usage: dict | None,
    ) -> None:
        content = str(text or "").strip()
        if not content:
            return
        bot_user = meeting_views._realtime_bot_system_user()
        msg = MeetingMessage.objects.create(
            meeting=self.meeting,
            sender_user=bot_user,
            sender_display_name_override=meeting_views._meeting_realtime_bot_display_name(self.meeting),
            is_realtime_bot=True,
            audio_mime_type=(audio_mime or "").strip()[:120],
            audio_base64=(audio_base64 or "").strip(),
            content=content[:2000],
        )
        payload = {
            "type": "result",
            "ok": True,
            "preview_text": content[:200],
            "message": MeetingMessageSerializer(msg).data,
        }
        if (recognized_text or "").strip():
            payload["recognized_text"] = str(recognized_text).strip()[:500]
        if usage:
            payload["usage"] = usage
        self._emit(payload)

    def _emit_error(self, detail: str) -> None:
        self._emit({"type": "error", "status": 500, "detail": detail})

    def _emit(self, payload: dict) -> None:
        self.emit(payload)


@sync_to_async
def _decode_audio_chunk(payload: dict) -> tuple[bytes, str]:
    audio_base64 = str(payload.get("audio_base64") or "").strip()
    if not audio_base64:
        return b"", "audio_base64 is required"
    sample_rate = meeting_views._coerce_sample_rate(payload.get("sample_rate"), default=16000)
    channels = meeting_views._coerce_channels(payload.get("channels"), default=1)
    try:
        audio_pcm16 = meeting_views._decode_and_normalize_pcm16_audio(
            audio_base64=audio_base64,
            sample_rate=sample_rate,
            channels=channels,
            target_sample_rate=16000,
        )
    except Exception as exc:
        return b"", f"Invalid audio payload: {exc}"
    if not audio_pcm16:
        return b"", "audio payload is empty"
    return audio_pcm16, ""


@sync_to_async
def _finalize_stream_turn(user: User, meeting: Meeting, audio_pcm16: bytes, client_ip: str) -> tuple[int, dict]:
    actor_membership = meeting_membership(meeting.id, user.id)
    if not can_moderate(user, actor_membership):
        return 403, {"detail": "Only host/cohost can send AI realtime audio"}
    if not meeting_views._meeting_realtime_bot_ready(meeting):
        return 400, {"detail": "Realtime bot is not enabled or not configured"}
    if not audio_pcm16:
        return 400, {"detail": "audio payload is empty"}

    try:
        reply_text, reply_audio_base64, reply_audio_mime = meeting_views._call_realtime_bot_with_audio(
            meeting=meeting,
            audio_pcm16=audio_pcm16,
            audio_sample_rate=16000,
        )
    except Exception as exc:
        return 400, {"detail": str(exc), "ok": False}

    content = (reply_text or "").strip()
    if not content:
        return 400, {"detail": "Realtime bot returned empty reply", "ok": False}

    bot_user = meeting_views._realtime_bot_system_user()
    msg = MeetingMessage.objects.create(
        meeting=meeting,
        sender_user=bot_user,
        sender_display_name_override=meeting_views._meeting_realtime_bot_display_name(meeting),
        is_realtime_bot=True,
        audio_mime_type=(reply_audio_mime or "").strip()[:120],
        audio_base64=(reply_audio_base64 or "").strip(),
        content=content[:2000],
    )
    return 200, {
        "ok": True,
        "preview_text": content[:200],
        "message": MeetingMessageSerializer(msg).data,
    }


def _finalize_stream_turn_sync(meeting: Meeting, audio_pcm16: bytes) -> tuple[int, dict]:
    if not meeting_views._meeting_realtime_bot_ready(meeting):
        return 400, {"detail": "Realtime bot is not enabled or not configured"}
    if not audio_pcm16:
        return 400, {"detail": "audio payload is empty"}

    try:
        reply_text, reply_audio_base64, reply_audio_mime = meeting_views._call_realtime_bot_with_audio(
            meeting=meeting,
            audio_pcm16=audio_pcm16,
            audio_sample_rate=16000,
        )
    except Exception as exc:
        return 400, {"detail": str(exc), "ok": False}

    content = (reply_text or "").strip()
    if not content:
        return 400, {"detail": "Realtime bot returned empty reply", "ok": False}

    bot_user = meeting_views._realtime_bot_system_user()
    msg = MeetingMessage.objects.create(
        meeting=meeting,
        sender_user=bot_user,
        sender_display_name_override=meeting_views._meeting_realtime_bot_display_name(meeting),
        is_realtime_bot=True,
        audio_mime_type=(reply_audio_mime or "").strip()[:120],
        audio_base64=(reply_audio_base64 or "").strip(),
        content=content[:2000],
    )
    return 200, {
        "ok": True,
        "preview_text": content[:200],
        "message": MeetingMessageSerializer(msg).data,
    }


async def realtime_audio_ws_application(scope, receive, send):
    path = scope.get("path", "")
    if scope.get("type") != "websocket" or not (_PATH_ID_RE.match(path) or _PATH_REF_RE.match(path)):
        await send({"type": "websocket.close", "code": 1008})
        return

    token = _extract_token(scope)
    user = await _authenticate_websocket_user(token)
    if not user:
        await send({"type": "websocket.close", "code": 4401})
        return

    meeting = await _meeting_for_scope(scope, user)
    if not meeting:
        await send({"type": "websocket.close", "code": 4404})
        return

    if not await _can_moderate_meeting(user, meeting):
        await send({"type": "websocket.close", "code": 4403})
        return

    ready_payload = await _meeting_ready_payload(meeting)
    if not ready_payload["ready"]:
        await send({"type": "websocket.close", "code": 4400})
        return

    await send({"type": "websocket.accept"})
    await _send_json(
        send,
        {
            "type": "ready",
            "meeting_id": ready_payload["meeting_id"],
            "provider": ready_payload["provider"],
            "streaming": ready_payload["streaming"],
        },
    )

    stream_open = False
    bridge_queue: asyncio.Queue[dict] = asyncio.Queue()
    bridge = None
    if ready_payload["streaming"]:
        loop = asyncio.get_running_loop()

        def _emit_from_bridge(payload: dict) -> None:
            loop.call_soon_threadsafe(bridge_queue.put_nowait, payload)

        bridge = _VolcengineRealtimeStreamBridge(meeting=meeting, emit=_emit_from_bridge)
        await sync_to_async(bridge.start, thread_sensitive=True)()

    while True:
        receive_task = asyncio.create_task(receive())
        queue_task = asyncio.create_task(bridge_queue.get()) if ready_payload["streaming"] else None
        wait_set = {receive_task}
        if queue_task is not None:
            wait_set.add(queue_task)
        done, pending = await asyncio.wait(wait_set, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        if queue_task is not None and queue_task in done:
            payload = queue_task.result()
            await _send_json(send, payload)
            continue
        event = receive_task.result()
        if event["type"] == "websocket.disconnect":
            if bridge is not None:
                await sync_to_async(bridge.close, thread_sensitive=True)()
            return
        if event["type"] != "websocket.receive":
            continue

        raw_text = event.get("text")
        if raw_text is None:
            continue

        try:
            payload = json.loads(raw_text)
        except json.JSONDecodeError:
            await _send_json(send, {"type": "error", "status": 400, "detail": "Invalid JSON"})
            continue

        if not isinstance(payload, dict):
            await _send_json(send, {"type": "error", "status": 400, "detail": "Invalid payload"})
            continue

        message_type = str(payload.get("type") or "").strip().lower()
        if message_type == "ping":
            await _send_json(send, {"type": "pong"})
            continue

        if ready_payload["streaming"]:
            if message_type in {"speech_start", "start"}:
                stream_open = True
                if bridge is not None:
                    await sync_to_async(bridge.start_turn, thread_sensitive=True)()
                await _send_json(send, {"type": "ack", "event": "speech_start"})
                continue
            if message_type in {"interrupt", "client_interrupt"}:
                stream_open = True
                if bridge is not None:
                    await sync_to_async(bridge.start_turn, thread_sensitive=True)()
                await _send_json(send, {"type": "ack", "event": "interrupt"})
                continue
            if message_type in {"audio_chunk", "chunk"}:
                audio_pcm16, err = await _decode_audio_chunk(payload)
                if err:
                    await _send_json(send, {"type": "error", "status": 400, "detail": err})
                    continue
                if not stream_open:
                    stream_open = True
                    if bridge is not None:
                        await sync_to_async(bridge.start_turn, thread_sensitive=True)()
                if bridge is not None:
                    await sync_to_async(bridge.send_audio_pcm16, thread_sensitive=True)(audio_pcm16)
                continue
            if message_type in {"speech_end", "end_asr", "end"}:
                await _send_json(send, {"type": "ack", "event": "speech_end"})
                if not stream_open or bridge is None:
                    await _send_json(send, {"type": "error", "status": 400, "detail": "audio payload is empty"})
                    stream_open = False
                    continue
                stream_open = False
                await sync_to_async(bridge.end_turn, thread_sensitive=True)()
                continue

        if message_type not in {"", "audio_ingress", "ingress", "audio"}:
            await _send_json(send, {"type": "error", "status": 400, "detail": "Unsupported message type"})
            continue

        audio_payload = {
            "audio_base64": str(payload.get("audio_base64") or "").strip(),
            "sample_rate": payload.get("sample_rate", 16000),
            "channels": payload.get("channels", 1),
        }
        status_code, body = await _invoke_audio_ingress(user, meeting, audio_payload, _client_ip(scope))
        if status_code >= 400:
            detail = ""
            if isinstance(body, dict):
                detail = str(body.get("detail") or "").strip()
            if not detail:
                detail = f"Audio ingress failed ({status_code})"
            await _send_json(
                send,
                {
                    "type": "error",
                    "status": status_code,
                    "detail": detail,
                    "payload": body,
                },
            )
            continue

        await _send_json(
            send,
            {"type": "result", **(body or {"ok": True})},
        )
