from django.utils import timezone
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from conference.meeting_context.serializers import (
    MeetingAgentActionSerializer,
    MeetingAgentConnectSerializer,
    MeetingAgentSessionSerializer,
    MeetingArtifactSerializer,
    MeetingContextSnapshotSerializer,
    MeetingTranscriptChunkCreateSerializer,
    MeetingTranscriptChunkSerializer,
)
from conference.meeting_context.services import (
    build_current_context,
    connect_agent_session,
    dispatch_agent_action,
    ensure_agent_session,
    get_or_build_current_context,
    store_agent_result,
)
from conference.models import Meeting, MeetingAgentPresence, MeetingArtifact, MeetingTranscriptChunk
from conference.utils import client_ip, has_meeting_access, log_audit


def _meeting_for_user_or_403(user, meeting_id: int):
    meeting = Meeting.objects.filter(id=meeting_id).first()
    if not meeting:
        return None, Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    if not has_meeting_access(user, meeting):
        return None, Response({"detail": "No permission to access this meeting"}, status=status.HTTP_403_FORBIDDEN)
    return meeting, None


@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def meeting_transcripts(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error

    if request.method == "GET":
        limit = max(1, min(int(request.GET.get("limit", 100)), 300))
        chunks = list(
            MeetingTranscriptChunk.objects.filter(meeting=meeting)
            .order_by("-sequence_no", "-created_at")[:limit]
        )
        chunks.reverse()
        return Response(MeetingTranscriptChunkSerializer(chunks, many=True).data)

    serializer = MeetingTranscriptChunkCreateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    last_sequence = (
        MeetingTranscriptChunk.objects.filter(meeting=meeting)
        .order_by("-sequence_no")
        .values_list("sequence_no", flat=True)
        .first()
        or 0
    )
    chunk = MeetingTranscriptChunk.objects.create(
        meeting=meeting,
        speaker_identity=serializer.validated_data.get("speaker_identity", ""),
        speaker_name=serializer.validated_data.get("speaker_name", ""),
        source=serializer.validated_data.get("source") or "manual",
        text=serializer.validated_data["text"].strip(),
        start_ms=serializer.validated_data.get("start_ms", 0),
        end_ms=serializer.validated_data.get("end_ms", 0),
        is_final=serializer.validated_data.get("is_final", True),
        confidence=serializer.validated_data.get("confidence", 1.0),
        sequence_no=last_sequence + 1,
    )
    build_current_context(meeting)
    log_audit(
        user=request.user,
        action="meeting.transcript_add",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"chunk_id={chunk.id}",
        ip_address=client_ip(request),
    )
    return Response(MeetingTranscriptChunkSerializer(chunk).data, status=status.HTTP_201_CREATED)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_context_current(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    snapshot = get_or_build_current_context(meeting)
    return Response(MeetingContextSnapshotSerializer(snapshot).data)


@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def meeting_agents(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error

    if request.method == "GET":
        sessions = list(
            meeting.agent_sessions.filter(owner_user=request.user).order_by("agent_type", "id")
        )
        return Response(MeetingAgentSessionSerializer(sessions, many=True).data)

    serializer = MeetingAgentConnectSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    session = ensure_agent_session(meeting, request.user, serializer.validated_data["agent_type"])
    session.presence_status = MeetingAgentPresence.CONNECTING
    session.current_task_title = "Connecting local agent"
    session.current_task_status = "connecting"
    session.last_used_at = timezone.now()
    session.save(
        update_fields=[
            "presence_status",
            "current_task_title",
            "current_task_status",
            "last_used_at",
            "updated_at",
        ]
    )
    session = connect_agent_session(session)
    log_audit(
        user=request.user,
        action="meeting.agent_connect",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"agent_type={session.agent_type}",
        ip_address=client_ip(request),
    )
    return Response(MeetingAgentSessionSerializer(session).data, status=status.HTTP_201_CREATED)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_agent_actions(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error

    serializer = MeetingAgentActionSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    agent_type = serializer.validated_data["agent_type"]
    task_type = serializer.validated_data["task_type"].strip().lower()
    instruction = serializer.validated_data.get("instruction", "").strip()
    chunk_ids = serializer.validated_data.get("chunk_ids") or []
    session = connect_agent_session(ensure_agent_session(meeting, request.user, agent_type))
    snapshot = get_or_build_current_context(meeting)
    chunks_qs = MeetingTranscriptChunk.objects.filter(meeting=meeting)
    if chunk_ids:
        chunks = list(chunks_qs.filter(id__in=chunk_ids).order_by("sequence_no", "created_at", "id"))
    else:
        source_ids = snapshot.source_chunk_ids[-8:] if snapshot.source_chunk_ids else []
        if source_ids:
            chunks = list(
                chunks_qs.filter(id__in=source_ids).order_by("sequence_no", "created_at", "id")
            )
        else:
            chunks = list(
                chunks_qs.order_by("-sequence_no", "-created_at", "-id")[:8]
            )
            chunks.reverse()

    session.presence_status = MeetingAgentPresence.WORKING
    session.current_task_title = task_type.replace("_", " ").title()
    session.current_task_status = "running"
    session.current_context_chunk_ids = [chunk.id for chunk in chunks]
    session.queue_size = 1
    session.save(
        update_fields=[
            "presence_status",
            "current_task_title",
            "current_task_status",
            "current_context_chunk_ids",
            "queue_size",
            "updated_at",
        ]
    )

    result = dispatch_agent_action(
        meeting=meeting,
        session=session,
        task_type=task_type,
        instruction=instruction,
        chunks=chunks,
        snapshot=snapshot,
    )
    artifact = store_agent_result(
        meeting=meeting,
        session=session,
        result=result,
        source_chunk_ids=[chunk.id for chunk in chunks],
        task_type=task_type,
    )
    log_audit(
        user=request.user,
        action="meeting.agent_action",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"agent_type={agent_type}, task_type={task_type}, artifact_id={artifact.id}",
        ip_address=client_ip(request),
    )
    return Response(
        {
            "session": MeetingAgentSessionSerializer(session).data,
            "artifact": MeetingArtifactSerializer(artifact).data,
            "context": MeetingContextSnapshotSerializer(snapshot).data,
        }
    )


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_artifacts(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    limit = max(1, min(int(request.GET.get("limit", 20)), 100))
    artifacts = list(MeetingArtifact.objects.filter(meeting=meeting).order_by("-created_at", "-id")[:limit])
    return Response(MeetingArtifactSerializer(artifacts, many=True).data)
