from dataclasses import dataclass


@dataclass(frozen=True)
class TranscriptDelta:
    message_type: str
    text: str
    chunk_count: int
    byte_count: int


@dataclass(frozen=True)
class AudioChunk:
    payload: bytes
    mime_type: str
