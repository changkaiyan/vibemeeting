from services.stt_worker.stt_worker.config import SttWorkerConfig
from services.stt_worker.stt_worker.schemas import TranscriptDelta
from services.stt_worker.stt_worker.providers.faster_whisper_provider import (
    FasterWhisperRealtimeProvider,
)


class MockRealtimeTranscriptionSession:
    def __init__(self, *, speaker_name: str = "", speaker_identity: str = ""):
        self.speaker_name = (speaker_name or "").strip()
        self.speaker_identity = (speaker_identity or "").strip()
        self.chunk_count = 0
        self.byte_count = 0

    def push_chunk(self, payload: bytes, *, mime_type: str = "") -> TranscriptDelta:
        raw = payload or b""
        self.chunk_count += 1
        self.byte_count += len(raw)
        speaker = self.speaker_name or self.speaker_identity or "Speaker"
        return TranscriptDelta(
            message_type="partial_transcript",
            text=f"{speaker} speaking... {self.chunk_count} chunks / {self.byte_count} bytes",
            chunk_count=self.chunk_count,
            byte_count=self.byte_count,
        )

    def finalize(self) -> TranscriptDelta:
        speaker = self.speaker_name or self.speaker_identity or "Speaker"
        return TranscriptDelta(
            message_type="final_transcript",
            text=f"Mock realtime transcript for {speaker}: {self.chunk_count} chunks, {self.byte_count} bytes received.",
            chunk_count=self.chunk_count,
            byte_count=self.byte_count,
        )


def build_realtime_session(
    config: SttWorkerConfig,
    *,
    speaker_name: str = "",
    speaker_identity: str = "",
):
    provider = (config.provider or "mock").strip().lower()
    if provider == "mock":
        return MockRealtimeTranscriptionSession(
            speaker_name=speaker_name,
            speaker_identity=speaker_identity,
        )
    if provider == "faster_whisper":
        return FasterWhisperRealtimeProvider(
            speaker_name=speaker_name,
            speaker_identity=speaker_identity,
            model_size=config.model_size,
            compute_type=config.compute_type,
            language=config.language,
            local_files_only=config.local_files_only,
        )
    raise ValueError(f"Unsupported STT worker provider: {config.provider}")
