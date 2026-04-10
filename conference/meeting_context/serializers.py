from rest_framework import serializers

from conference.models import (
    MeetingAgentSession,
    MeetingAgentType,
    MeetingArtifact,
    MeetingContextSnapshot,
    MeetingTranscriptChunk,
    MeetingTranscriptSource,
)


class MeetingTranscriptChunkSerializer(serializers.ModelSerializer):
    class Meta:
        model = MeetingTranscriptChunk
        fields = (
            "id",
            "speaker_identity",
            "speaker_name",
            "source",
            "text",
            "start_ms",
            "end_ms",
            "is_final",
            "confidence",
            "sequence_no",
            "created_at",
        )


class MeetingTranscriptChunkCreateSerializer(serializers.Serializer):
    speaker_identity = serializers.CharField(required=False, allow_blank=True, max_length=120)
    speaker_name = serializers.CharField(required=False, allow_blank=True, max_length=80)
    source = serializers.ChoiceField(required=False, choices=MeetingTranscriptSource.choices)
    text = serializers.CharField(max_length=4000)
    start_ms = serializers.IntegerField(required=False, min_value=0, default=0)
    end_ms = serializers.IntegerField(required=False, min_value=0, default=0)
    is_final = serializers.BooleanField(required=False, default=True)
    confidence = serializers.FloatField(required=False, min_value=0.0, max_value=1.0, default=1.0)


class MeetingContextSnapshotSerializer(serializers.ModelSerializer):
    class Meta:
        model = MeetingContextSnapshot
        fields = (
            "id",
            "window_start_ms",
            "window_end_ms",
            "topic_label",
            "summary_text",
            "open_questions",
            "decisions",
            "todos",
            "source_chunk_ids",
            "version",
            "created_at",
        )


class MeetingAgentSessionSerializer(serializers.ModelSerializer):
    class Meta:
        model = MeetingAgentSession
        fields = (
            "id",
            "agent_type",
            "display_name",
            "presence_status",
            "current_task_title",
            "current_task_status",
            "current_context_chunk_ids",
            "latest_short_reply",
            "latest_result_artifact_id",
            "queue_size",
            "bridge_online",
            "last_latency_ms",
            "last_error",
            "last_used_at",
            "updated_at",
        )


class MeetingAgentConnectSerializer(serializers.Serializer):
    agent_type = serializers.ChoiceField(choices=MeetingAgentType.choices)


class MeetingAgentActionSerializer(serializers.Serializer):
    agent_type = serializers.ChoiceField(choices=MeetingAgentType.choices)
    task_type = serializers.CharField(max_length=40)
    instruction = serializers.CharField(required=False, allow_blank=True, max_length=4000)
    chunk_ids = serializers.ListField(
        child=serializers.IntegerField(min_value=1),
        required=False,
        allow_empty=True,
    )


class MeetingArtifactSerializer(serializers.ModelSerializer):
    class Meta:
        model = MeetingArtifact
        fields = (
            "id",
            "agent_session_id",
            "artifact_type",
            "title",
            "content",
            "source_chunk_ids",
            "created_at",
            "updated_at",
        )
