import json
import re
from dataclasses import dataclass
from urllib.parse import parse_qs

from asgiref.sync import sync_to_async
from django.contrib.auth.models import User
from rest_framework_simplejwt.authentication import JWTAuthentication
from rest_framework_simplejwt.exceptions import InvalidToken, TokenError

from conference.meeting_context.services import build_current_context
from conference.models import Meeting, MeetingTranscriptChunk, MeetingTranscriptSource
from conference.speech_to_text import SpeechToTextError, SpeechToTextUnavailable
from conference.speech_to_text.services import realtime_worker_url
from conference.speech_to_text.worker_client import WorkerRealtimeBridge
from conference.utils import has_meeting_access

_PATH_RE = re.compile(r"^/ws/meetings/(?P<meeting_id>\d+)/stt/?$")


@dataclass
class RealtimeSpeechSession:
    meeting: Meeting
    user: User
    speaker_name: str = ""
    speaker_identity: str = ""
    worker_bridge: WorkerRealtimeBridge | None = None


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
def _meeting_for_user(meeting_id: int, user: User) -> Meeting | None:
    meeting = Meeting.objects.filter(id=meeting_id).first()
    if not meeting:
        return None
    if not has_meeting_access(user, meeting):
        return None
    return meeting


@sync_to_async
def _persist_final_chunk(session: RealtimeSpeechSession, text: str) -> MeetingTranscriptChunk:
    last_sequence = (
        MeetingTranscriptChunk.objects.filter(meeting=session.meeting)
        .order_by("-sequence_no")
        .values_list("sequence_no", flat=True)
        .first()
        or 0
    )
    chunk = MeetingTranscriptChunk.objects.create(
        meeting=session.meeting,
        speaker_identity=session.speaker_identity,
        speaker_name=session.speaker_name,
        source=MeetingTranscriptSource.LIVE,
        text=text,
        is_final=True,
        confidence=1.0,
        sequence_no=last_sequence + 1,
    )
    build_current_context(session.meeting)
    return chunk


async def _send_json(send, payload: dict) -> None:
    await send({"type": "websocket.send", "text": json.dumps(payload)})


async def _close_worker_bridge(session: RealtimeSpeechSession) -> None:
    if session.worker_bridge is not None:
        await session.worker_bridge.close()
        session.worker_bridge = None


async def realtime_stt_application(scope, receive, send):
    match = _PATH_RE.match(scope.get("path", ""))
    if scope.get("type") != "websocket" or not match:
        await send({"type": "websocket.close", "code": 1008})
        return

    token = _extract_token(scope)
    user = await _authenticate_websocket_user(token)
    if not user:
        await send({"type": "websocket.close", "code": 4401})
        return

    meeting = await _meeting_for_user(int(match.group("meeting_id")), user)
    if not meeting:
        await send({"type": "websocket.close", "code": 4403})
        return

    session = RealtimeSpeechSession(meeting=meeting, user=user)
    await send({"type": "websocket.accept"})

    try:
        while True:
            event = await receive()
            if event["type"] == "websocket.disconnect":
                return
            if event["type"] != "websocket.receive":
                continue

            if event.get("text") is None:
                continue
            try:
                payload = json.loads(event["text"])
            except json.JSONDecodeError:
                await _send_json(send, {"type": "error", "detail": "Invalid JSON"})
                continue

            message_type = (payload.get("type") or "").strip().lower()
            if message_type == "start":
                worker_url = realtime_worker_url()
                if not worker_url:
                    await _send_json(send, {"type": "error", "detail": "Realtime STT worker is not configured"})
                    continue

                await _close_worker_bridge(session)
                session.speaker_name = (payload.get("speaker_name") or "").strip()[:80]
                session.speaker_identity = (payload.get("speaker_identity") or "").strip()[:120]
                session.worker_bridge = WorkerRealtimeBridge(worker_url)
                try:
                    await session.worker_bridge.connect()
                    response = await session.worker_bridge.start_session(
                        speaker_name=session.speaker_name,
                        speaker_identity=session.speaker_identity,
                    )
                except (SpeechToTextError, SpeechToTextUnavailable) as exc:
                    await _close_worker_bridge(session)
                    await _send_json(send, {"type": "error", "detail": str(exc)})
                    continue
                response["meeting_id"] = session.meeting.id
                await _send_json(send, response)
                continue

            if message_type == "audio_chunk":
                if session.worker_bridge is None:
                    await _send_json(send, {"type": "error", "detail": "Realtime STT session is not started"})
                    continue
                try:
                    response = await session.worker_bridge.push_audio_chunk(
                        mime_type=(payload.get("mime_type") or "").strip(),
                        data_base64=(payload.get("data_base64") or "").strip(),
                    )
                except (SpeechToTextError, SpeechToTextUnavailable) as exc:
                    await _send_json(send, {"type": "error", "detail": str(exc)})
                    continue
                await _send_json(send, response)
                continue

            if message_type == "stop":
                if session.worker_bridge is None:
                    await _send_json(send, {"type": "error", "detail": "Realtime STT session is not started"})
                    continue
                try:
                    response = await session.worker_bridge.stop_session()
                except (SpeechToTextError, SpeechToTextUnavailable) as exc:
                    await _send_json(send, {"type": "error", "detail": str(exc)})
                    continue
                finally:
                    await _close_worker_bridge(session)

                final_text = (response.get("text") or "").strip()
                chunk = await _persist_final_chunk(session, final_text)
                await _send_json(
                    send,
                    {
                        "type": "final_transcript",
                        "id": chunk.id,
                        "speaker_name": chunk.speaker_name,
                        "speaker_identity": chunk.speaker_identity,
                        "text": chunk.text,
                        "source": chunk.source,
                        "sequence_no": chunk.sequence_no,
                    },
                )
                continue

            await _send_json(send, {"type": "error", "detail": f"Unsupported message type: {message_type or 'unknown'}"})
    finally:
        await _close_worker_bridge(session)
