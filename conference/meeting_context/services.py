from dataclasses import dataclass

from django.utils import timezone

from conference.meeting_agent_bridge import is_mock_mode, run_bridge_action
from conference.models import (
    Meeting,
    MeetingAgentPresence,
    MeetingAgentSession,
    MeetingAgentType,
    MeetingArtifact,
    MeetingArtifactType,
    MeetingContextSnapshot,
    MeetingTranscriptChunk,
)


def agent_display_name(agent_type: str) -> str:
    return {
        MeetingAgentType.CODEX: "Alice / Codex",
        MeetingAgentType.CLAUDE: "Bob / Claude",
    }.get(agent_type, agent_type.title())


def build_current_context(meeting: Meeting) -> MeetingContextSnapshot:
    chunks = list(
        MeetingTranscriptChunk.objects.filter(meeting=meeting, is_final=True)
        .order_by("-sequence_no", "-created_at")[:20]
    )
    chunks.reverse()
    source_ids = [chunk.id for chunk in chunks]
    window_start_ms = chunks[0].start_ms if chunks else 0
    window_end_ms = chunks[-1].end_ms if chunks else 0
    topic_label = meeting.title
    if chunks and not topic_label:
        topic_label = chunks[-1].text[:40]
    summary_lines = [f"{chunk.speaker_name or chunk.speaker_identity or 'Speaker'}: {chunk.text}" for chunk in chunks[-5:]]
    summary_text = "\n".join(summary_lines)
    todos = [
        line
        for line in (
            "Follow up on unresolved implementation details" if chunks else "",
            "Convert meeting decisions into executable tasks" if len(chunks) >= 3 else "",
        )
        if line
    ]
    snapshot = MeetingContextSnapshot.objects.create(
        meeting=meeting,
        window_start_ms=window_start_ms,
        window_end_ms=window_end_ms,
        topic_label=topic_label[:120],
        summary_text=summary_text,
        open_questions=[],
        decisions=[],
        todos=todos,
        source_chunk_ids=source_ids,
        version=(MeetingContextSnapshot.objects.filter(meeting=meeting).count() + 1),
    )
    return snapshot


def get_or_build_current_context(meeting: Meeting) -> MeetingContextSnapshot:
    snapshot = MeetingContextSnapshot.objects.filter(meeting=meeting).order_by("-created_at", "-id").first()
    if snapshot:
        return snapshot
    return build_current_context(meeting)


def ensure_agent_session(meeting: Meeting, owner_user, agent_type: str) -> MeetingAgentSession:
    session, created = MeetingAgentSession.objects.get_or_create(
        meeting=meeting,
        owner_user=owner_user,
        agent_type=agent_type,
        defaults={
            "display_name": agent_display_name(agent_type),
            "presence_status": MeetingAgentPresence.CONNECTING,
            "bridge_online": False,
        },
    )
    if created and not session.display_name:
        session.display_name = agent_display_name(agent_type)
        session.save(update_fields=["display_name"])
    return session


def connect_agent_session(session: MeetingAgentSession) -> MeetingAgentSession:
    session.display_name = session.display_name or agent_display_name(session.agent_type)
    session.bridge_online = True
    session.presence_status = MeetingAgentPresence.IDLE
    session.last_error = ""
    session.last_used_at = timezone.now()
    session.save(
        update_fields=[
            "display_name",
            "bridge_online",
            "presence_status",
            "last_error",
            "last_used_at",
            "updated_at",
        ]
    )
    return session


def agent_session_is_busy(session: MeetingAgentSession) -> bool:
    if session.current_task_status.strip().lower() == "running":
        return True
    return session.queue_size > 0 and session.presence_status == MeetingAgentPresence.WORKING


def mark_agent_session_error(session: MeetingAgentSession, message: str) -> MeetingAgentSession:
    session.display_name = session.display_name or agent_display_name(session.agent_type)
    session.bridge_online = False
    session.presence_status = MeetingAgentPresence.ERROR
    session.current_task_status = "error"
    session.last_error = message.strip()[:1000]
    session.queue_size = 0
    session.last_used_at = timezone.now()
    session.save(
        update_fields=[
            "display_name",
            "bridge_online",
            "presence_status",
            "current_task_status",
            "last_error",
            "queue_size",
            "last_used_at",
            "updated_at",
        ]
    )
    return session


@dataclass
class AgentDispatchResult:
    short_reply: str
    artifact_type: str
    artifact_title: str
    artifact_content: str
    latency_ms: int


def _mock_reply(agent_type: str, task_type: str, instruction: str, chunks: list[MeetingTranscriptChunk], snapshot: MeetingContextSnapshot) -> AgentDispatchResult:
    quoted = "\n".join(
        f"- {chunk.speaker_name or chunk.speaker_identity or 'Speaker'}: {chunk.text}"
        for chunk in chunks[:5]
    )
    if task_type == "summarize":
        content = f"Current topic: {snapshot.topic_label or 'Meeting discussion'}\n\nRecent discussion:\n{quoted or snapshot.summary_text or 'No transcript yet.'}"
        return AgentDispatchResult(
            short_reply="I summarized the current discussion.",
            artifact_type=MeetingArtifactType.SUMMARY,
            artifact_title=f"{agent_display_name(agent_type)} summary",
            artifact_content=content,
            latency_ms=80,
        )
    if task_type == "extract_todos":
        content = "\n".join(
            [
                "1. Review latest meeting decisions",
                "2. Convert requirements into implementation tasks",
                "3. Confirm owner and deadline for follow-up items",
            ]
        )
        return AgentDispatchResult(
            short_reply="I extracted a lightweight todo list.",
            artifact_type=MeetingArtifactType.TODO,
            artifact_title=f"{agent_display_name(agent_type)} todos",
            artifact_content=content,
            latency_ms=90,
        )
    if task_type == "draft_api":
        content = (
            "Suggested API draft\n"
            "POST /api/meetings/{meeting_id}/agent-actions\n"
            "GET /api/meetings/{meeting_id}/context/current\n"
            "GET /api/meetings/{meeting_id}/artifacts\n"
        )
        return AgentDispatchResult(
            short_reply="I drafted a minimal API shape.",
            artifact_type=MeetingArtifactType.CODE_TASK,
            artifact_title=f"{agent_display_name(agent_type)} API draft",
            artifact_content=content,
            latency_ms=95,
        )
    content = (
        f"Instruction\n{instruction or '(empty)'}\n\n"
        f"Context topic\n{snapshot.topic_label or 'N/A'}\n\n"
        f"Recent transcript\n{quoted or snapshot.summary_text or 'No transcript yet.'}"
    )
    return AgentDispatchResult(
        short_reply="I processed the request with the current meeting context.",
        artifact_type=MeetingArtifactType.REPLY,
        artifact_title=f"{agent_display_name(agent_type)} reply",
        artifact_content=content,
        latency_ms=70,
    )


def dispatch_agent_action(
    *,
    meeting: Meeting,
    session: MeetingAgentSession,
    task_type: str,
    instruction: str,
    chunks: list[MeetingTranscriptChunk],
    snapshot: MeetingContextSnapshot,
) -> AgentDispatchResult:
    body = {
        "meeting_id": meeting.id,
        "agent_type": session.agent_type,
        "task_type": task_type,
        "instruction": instruction,
        "context": {
            "topic_label": snapshot.topic_label,
            "summary_text": snapshot.summary_text,
            "decisions": snapshot.decisions,
            "todos": snapshot.todos,
            "open_questions": snapshot.open_questions,
            "source_chunk_ids": snapshot.source_chunk_ids,
        },
        "chunks": [
            {
                "id": chunk.id,
                "speaker_name": chunk.speaker_name,
                "speaker_identity": chunk.speaker_identity,
                "text": chunk.text,
                "start_ms": chunk.start_ms,
                "end_ms": chunk.end_ms,
            }
            for chunk in chunks
        ],
    }
    if is_mock_mode():
        return _mock_reply(session.agent_type, task_type, instruction, chunks, snapshot)

    payload, latency_ms = run_bridge_action(body)
    return AgentDispatchResult(
        short_reply=(payload.get("short_reply") or "Agent replied").strip(),
        artifact_type=(payload.get("artifact_type") or MeetingArtifactType.REPLY),
        artifact_title=(payload.get("artifact_title") or f"{agent_display_name(session.agent_type)} reply").strip(),
        artifact_content=(payload.get("artifact_content") or payload.get("content") or "").strip(),
        latency_ms=latency_ms,
    )


def store_agent_result(
    *,
    meeting: Meeting,
    session: MeetingAgentSession,
    result: AgentDispatchResult,
    source_chunk_ids: list[int],
    task_type: str,
) -> MeetingArtifact:
    artifact = MeetingArtifact.objects.create(
        meeting=meeting,
        agent_session=session,
        artifact_type=result.artifact_type,
        title=result.artifact_title or task_type.replace("_", " ").title(),
        content=result.artifact_content,
        source_chunk_ids=source_chunk_ids,
    )
    session.latest_short_reply = result.short_reply
    session.latest_result_artifact = artifact
    session.current_task_status = "done"
    session.presence_status = MeetingAgentPresence.IDLE
    session.queue_size = 0
    session.last_latency_ms = result.latency_ms
    session.last_error = ""
    session.last_used_at = timezone.now()
    session.save(
        update_fields=[
            "latest_short_reply",
            "latest_result_artifact",
            "current_task_status",
            "presence_status",
            "queue_size",
            "last_latency_ms",
            "last_error",
            "last_used_at",
            "updated_at",
        ]
    )
    return artifact
