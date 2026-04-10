from abc import ABC, abstractmethod

from services.stt_worker.stt_worker.schemas import TranscriptDelta


class RealtimeTranscriptionProvider(ABC):
    @abstractmethod
    def push_chunk(self, payload: bytes) -> TranscriptDelta:
        raise NotImplementedError

    @abstractmethod
    def finalize(self) -> TranscriptDelta:
        raise NotImplementedError
