import os

from django.conf import settings

from conference.speech_to_text.exceptions import SpeechToTextUnavailable


def provider_mode() -> str:
    mode = (getattr(settings, "MEETING_STT_PROVIDER", "") or "").strip().lower()
    return mode or "disabled"


def realtime_worker_url() -> str:
    return (getattr(settings, "MEETING_REALTIME_STT_WORKER_URL", "") or "").strip()


def _mock_transcript(uploaded_file) -> str:
    filename = os.path.basename(getattr(uploaded_file, "name", "") or "audio")
    return f"Mock STT transcript from {filename}"


def transcribe_uploaded_audio(uploaded_file) -> str:
    mode = provider_mode()
    if mode == "mock":
        return _mock_transcript(uploaded_file)
    raise SpeechToTextUnavailable("STT provider is not configured")
