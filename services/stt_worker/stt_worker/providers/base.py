from abc import ABC, abstractmethod

from services.stt_worker.stt_worker.schemas import TranscriptDelta


class RealtimeTranscriptionProvider(ABC):
    @abstractmethod
    def push_chunk(self, payload: bytes, *, mime_type: str = "") -> TranscriptDelta:
        raise NotImplementedError

    @abstractmethod
    def decode_partial(self, audio_window: bytes | None = None) -> str:
        raise NotImplementedError

    @abstractmethod
    def finalize(self) -> TranscriptDelta:
        raise NotImplementedError
