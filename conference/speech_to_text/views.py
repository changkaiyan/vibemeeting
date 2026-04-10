from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from conference.meeting_context.services import build_current_context
from conference.meeting_context.serializers import MeetingTranscriptChunkSerializer
from conference.meeting_context.views import _meeting_for_user_or_403
from conference.models import MeetingTranscriptChunk, MeetingTranscriptSource
from conference.speech_to_text import SpeechToTextError, transcribe_uploaded_audio
from conference.speech_to_text.serializers import SpeechToTextUploadSerializer
from conference.utils import client_ip, log_audit


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_stt_upload(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error

    serializer = SpeechToTextUploadSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)

    try:
        transcript_text = transcribe_uploaded_audio(serializer.validated_data["audio_file"]).strip()
    except SpeechToTextError as exc:
        return Response({"detail": str(exc)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)

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
        source=MeetingTranscriptSource.STT_UPLOAD,
        text=transcript_text,
        is_final=True,
        confidence=1.0,
        sequence_no=last_sequence + 1,
    )
    build_current_context(meeting)
    log_audit(
        user=request.user,
        action="meeting.transcript_stt_upload",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"chunk_id={chunk.id}",
        ip_address=client_ip(request),
    )
    return Response(MeetingTranscriptChunkSerializer(chunk).data, status=status.HTTP_201_CREATED)
