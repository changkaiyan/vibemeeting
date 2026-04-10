from rest_framework import serializers


class SpeechToTextUploadSerializer(serializers.Serializer):
    audio_file = serializers.FileField()
    speaker_identity = serializers.CharField(required=False, allow_blank=True, max_length=120)
    speaker_name = serializers.CharField(required=False, allow_blank=True, max_length=80)

    def validate_audio_file(self, value):
        content_type = (getattr(value, "content_type", "") or "").lower()
        if not content_type.startswith("audio/"):
            raise serializers.ValidationError("audio_file must be an audio file")
        return value
