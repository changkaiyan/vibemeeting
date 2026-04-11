import threading
import time
from types import SimpleNamespace
from urllib.parse import parse_qs
from uuid import uuid4

from asgiref.sync import async_to_sync
from channels.generic.websocket import JsonWebsocketConsumer
from django.contrib.auth import get_user_model
from django.db import close_old_connections
from rest_framework_simplejwt.tokens import AccessToken

from conference import views as meeting_views
from conference.meeting_refs import meeting_from_ref
from conference.models import Meeting, MeetingMessage, RealtimeBotProvider
from conference.serializers import MeetingMessageSerializer
from conference.utils import can_moderate, has_meeting_access, meeting_membership


class _VolcengineRealtimeStreamBridge:
    def __init__(self, *, consumer: "MeetingRealtimeAudioIngressConsumer", meeting):
        self.consumer = consumer
        self.meeting = meeting
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
        speaker = meeting_views._meeting_realtime_bot_volc_speaker(
            self.meeting, dialog_model=dialog_model
        )

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
                asr_text, is_interim = meeting_views._extract_asr_text_from_volcengine_payload(
                    payload_msg
                )
                if asr_text:
                    with self._state_lock:
                        if is_interim:
                            self._turn_asr_latest_interim = asr_text
                        elif (
                            not self._turn_asr_final_chunks
                            or asr_text != self._turn_asr_final_chunks[-1]
                        ):
                            self._turn_asr_final_chunks.append(asr_text)
                    self._emit(
                        {
                            "type": "asr",
                            "text": asr_text,
                            "is_interim": bool(is_interim),
                        }
                    )
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
                    self._emit(
                        {
                            "type": "no_content",
                            "detail": "asr no content",
                        }
                    )
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
            if (
                self._request_audio
                and self._turn_text_done
                and not self._turn_audio_done
            ):
                text_done_at = self._turn_text_done_at or self._turn_started_at or now
                text_wait = now - text_done_at
                if self._turn_audio_pcm_bytes:
                    last_audio_at = self._turn_last_audio_at or text_done_at
                    if now - last_audio_at >= 0.8:
                        self._turn_audio_done = True
                elif text_wait >= 1.6:
                    # Text has completed but no TTS end signal was received;
                    # finalize this turn as text-only to avoid random hangs.
                    self._turn_audio_done = True

            if (
                self._turn_asr_done_at > 0
                and not self._turn_text_chunks
                and not self._turn_audio_pcm_bytes
            ):
                asr_wait = now - self._turn_asr_done_at
                recognized_text = "".join(
                    part for part in self._turn_asr_final_chunks if str(part).strip()
                ).strip()
                if not recognized_text:
                    recognized_text = str(self._turn_asr_latest_interim or "").strip()

                if (
                    recognized_text
                    and not self._turn_fallback_attempted
                    and asr_wait >= 1.6
                ):
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
                fallback_text, fallback_audio_base64, fallback_audio_mime = (
                    meeting_views._call_realtime_bot_via_volcengine_websocket(
                        meeting=self.meeting,
                        prompt=fallback_prompt,
                        request_audio=self._request_audio,
                    )
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
            self._emit(
                {
                    "type": "no_content",
                    "detail": "asr no content timeout",
                }
            )

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
            audio_base64 = meeting_views._pcm16le_to_wav_base64(
                audio_bytes,
                sample_rate=24000,
                channels=1,
            )
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
        layer = getattr(self.consumer, "channel_layer", None)
        channel_name = getattr(self.consumer, "channel_name", "")
        if layer is None or not channel_name:
            return
        try:
            async_to_sync(layer.send)(
                channel_name,
                {
                    "type": "bridge_emit",
                    "payload": payload,
                },
            )
        except Exception:
            pass


class MeetingRealtimeAudioIngressConsumer(JsonWebsocketConsumer):
    def connect(self):
        self.user = self._resolve_scope_user()
        self.meeting = self._resolve_scope_meeting(self.user)
        self._inflight = False
        self._stream_turn_open = False
        self._stream_end_timer: threading.Timer | None = None
        self._stream_state_lock = threading.Lock()
        self._bridge: _VolcengineRealtimeStreamBridge | None = None

        if not self.user or not getattr(self.user, "is_authenticated", False):
            self.close(code=4401)
            return
        if self.meeting is None:
            self.close(code=4404)
            return
        actor_membership = meeting_membership(self.meeting.id, self.user.id)
        if not can_moderate(self.user, actor_membership):
            self.close(code=4403)
            return
        if not meeting_views._meeting_realtime_bot_ready(self.meeting):
            self.close(code=4400)
            return

        self.accept()
        provider = meeting_views._meeting_realtime_bot_provider(self.meeting)
        try:
            if provider == RealtimeBotProvider.VOLCENGINE:
                bridge = _VolcengineRealtimeStreamBridge(consumer=self, meeting=self.meeting)
                bridge.start()
                self._bridge = bridge
        except Exception as exc:
            self.send_json({"type": "error", "status": 500, "detail": f"Volc bridge start failed: {exc}"})
            self.close(code=1011)
            return

        self.send_json(
            {
                "type": "ready",
                "meeting_id": self.meeting.id,
                "provider": provider,
                "streaming": self._bridge is not None,
            }
        )

    def disconnect(self, code):
        self._cancel_stream_auto_end_timer()
        bridge = self._bridge
        self._bridge = None
        if bridge is not None:
            bridge.close()
        return super().disconnect(code)

    def _cancel_stream_auto_end_timer(self) -> None:
        timer = None
        with self._stream_state_lock:
            timer = self._stream_end_timer
            self._stream_end_timer = None
        if timer is not None:
            try:
                timer.cancel()
            except Exception:
                pass

    def _arm_stream_auto_end_timer(self, bridge: _VolcengineRealtimeStreamBridge) -> None:
        self._cancel_stream_auto_end_timer()

        def _auto_end() -> None:
            close_old_connections()
            with self._stream_state_lock:
                if not self._stream_turn_open:
                    return
                if bridge is not self._bridge:
                    return
                self._stream_turn_open = False
                self._stream_end_timer = None
            try:
                bridge.end_turn()
            except Exception:
                pass

        with self._stream_state_lock:
            if not self._stream_turn_open:
                return
            if bridge is not self._bridge:
                return
            timer = threading.Timer(2.2, _auto_end)
            timer.daemon = True
            self._stream_end_timer = timer
        timer.start()

    def receive_json(self, content, **kwargs):
        if not isinstance(content, dict):
            self.send_json({"type": "error", "status": 400, "detail": "Invalid payload"})
            return

        message_type = str(content.get("type") or "").strip().lower()
        if message_type == "ping":
            self.send_json({"type": "pong"})
            return

        bridge = self._bridge
        if bridge is not None:
            self._receive_json_streaming(content, message_type, bridge)
            return

        if message_type not in {"", "audio_ingress", "ingress", "audio"}:
            self.send_json({"type": "error", "status": 400, "detail": "Unsupported message type"})
            return
        audio_base64 = str(content.get("audio_base64") or "").strip()
        if not audio_base64:
            self.send_json({"type": "error", "status": 400, "detail": "audio_base64 is required"})
            return
        if self._inflight:
            self.send_json({"type": "error", "status": 429, "detail": "Previous audio chunk is still processing"})
            return

        payload = {
            "audio_base64": audio_base64,
            "sample_rate": content.get("sample_rate", 16000),
            "channels": content.get("channels", 1),
        }
        self._inflight = True
        try:
            fake_request = SimpleNamespace(
                user=self.user,
                data=payload,
                META={"REMOTE_ADDR": self._client_ip()},
            )
            response = meeting_views._meeting_ai_audio_ingress_impl(
                fake_request,
                self.meeting,
                int(self.meeting.id),
            )
            status_code = int(getattr(response, "status_code", 500) or 500)
            body = getattr(response, "data", None)
            if status_code >= 400:
                detail = ""
                if isinstance(body, dict):
                    detail = str(body.get("detail") or "").strip()
                if not detail:
                    detail = f"Audio ingress failed ({status_code})"
                self.send_json(
                    {
                        "type": "error",
                        "status": status_code,
                        "detail": detail,
                        "payload": body if isinstance(body, dict) else None,
                    }
                )
                return
            if isinstance(body, dict):
                self.send_json({"type": "result", **body})
            else:
                self.send_json({"type": "result", "ok": True})
        except Exception as exc:
            self.send_json({"type": "error", "status": 500, "detail": str(exc)})
        finally:
            self._inflight = False

    def bridge_emit(self, event):
        payload = event.get("payload")
        if isinstance(payload, dict):
            self.send_json(payload)

    def _receive_json_streaming(self, content: dict, message_type: str, bridge: _VolcengineRealtimeStreamBridge):
        if message_type in {"speech_start", "start"}:
            with self._stream_state_lock:
                self._stream_turn_open = True
            bridge.start_turn()
            self._arm_stream_auto_end_timer(bridge)
            self.send_json({"type": "ack", "event": "speech_start"})
            return
        if message_type in {"speech_end", "end_asr", "end"}:
            self._cancel_stream_auto_end_timer()
            should_end = False
            with self._stream_state_lock:
                should_end = self._stream_turn_open
                self._stream_turn_open = False
            if should_end:
                bridge.end_turn()
            self.send_json({"type": "ack", "event": "speech_end"})
            return
        if message_type in {"interrupt", "client_interrupt"}:
            self._cancel_stream_auto_end_timer()
            with self._stream_state_lock:
                self._stream_turn_open = True
            bridge.start_turn()
            self._arm_stream_auto_end_timer(bridge)
            self.send_json({"type": "ack", "event": "interrupt"})
            return

        if message_type in {"audio_chunk", "chunk"}:
            audio_pcm16, err = self._decode_audio_payload(content)
            if err:
                self.send_json({"type": "error", "status": 400, "detail": err})
                return
            should_start = False
            with self._stream_state_lock:
                if not self._stream_turn_open:
                    self._stream_turn_open = True
                    should_start = True
            if should_start:
                bridge.start_turn()
            bridge.send_audio_pcm16(audio_pcm16)
            self._arm_stream_auto_end_timer(bridge)
            return

        if message_type in {"", "audio_ingress", "ingress", "audio"}:
            audio_pcm16, err = self._decode_audio_payload(content)
            if err:
                self.send_json({"type": "error", "status": 400, "detail": err})
                return
            self._cancel_stream_auto_end_timer()
            with self._stream_state_lock:
                self._stream_turn_open = False
            bridge.start_turn()
            bridge.send_audio_pcm16(audio_pcm16)
            bridge.end_turn()
            return

        self.send_json({"type": "error", "status": 400, "detail": "Unsupported message type"})

    def _decode_audio_payload(self, content: dict) -> tuple[bytes, str]:
        audio_base64 = str(content.get("audio_base64") or "").strip()
        if not audio_base64:
            return b"", "audio_base64 is required"
        sample_rate = meeting_views._coerce_sample_rate(content.get("sample_rate"), default=16000)
        channels = meeting_views._coerce_channels(content.get("channels"), default=1)
        try:
            pcm16 = meeting_views._decode_and_normalize_pcm16_audio(
                audio_base64=audio_base64,
                sample_rate=sample_rate,
                channels=channels,
                target_sample_rate=16000,
            )
        except Exception as exc:
            return b"", f"Invalid audio payload: {exc}"
        if not pcm16:
            return b"", "audio payload is empty"
        return pcm16, ""

    def _resolve_scope_user(self):
        user = self.scope.get("user")
        if user is not None and getattr(user, "is_authenticated", False):
            return user
        return self._user_from_query_token()

    def _resolve_scope_meeting(self, user):
        if user is None or not getattr(user, "is_authenticated", False):
            return None
        route_kwargs = (self.scope.get("url_route") or {}).get("kwargs") or {}
        meeting_ref = str(route_kwargs.get("meeting_ref") or "").strip()
        if meeting_ref:
            return meeting_from_ref(user, meeting_ref)

        meeting_id_raw = str(route_kwargs.get("meeting_id") or "").strip()
        try:
            meeting_id = int(meeting_id_raw)
        except (TypeError, ValueError):
            return None
        meeting = Meeting.objects.filter(id=meeting_id).first()
        if meeting is None:
            return None
        if not has_meeting_access(user, meeting):
            return None
        return meeting

    def _user_from_query_token(self):
        raw_query = (self.scope.get("query_string") or b"").decode("utf-8", "ignore")
        token = str(parse_qs(raw_query).get("token", [""])[0] or "").strip()
        if not token:
            return None
        try:
            payload = AccessToken(token)
        except Exception:
            return None
        user_id = payload.get("user_id")
        if not user_id:
            return None
        user_model = get_user_model()
        return user_model.objects.filter(id=user_id, is_active=True).first()

    def _client_ip(self) -> str:
        client = self.scope.get("client")
        if isinstance(client, (list, tuple)) and client:
            return str(client[0])
        return "unknown"
