from tempfile import NamedTemporaryFile

from faster_whisper import WhisperModel

from services.stt_worker.stt_worker.providers.base import RealtimeTranscriptionProvider
from services.stt_worker.stt_worker.schemas import TranscriptDelta


class FasterWhisperRealtimeProvider(RealtimeTranscriptionProvider):
    _model_cache: dict[tuple[str, str], WhisperModel] = {}

    def __init__(
        self,
        *,
        speaker_name: str = "",
        speaker_identity: str = "",
        model_size: str = "small",
        compute_type: str = "int8",
        language: str = "zh",
        local_files_only: bool = False,
    ):
        self._buffer = bytearray()
        self.speaker_name = (speaker_name or "").strip()
        self.speaker_identity = (speaker_identity or "").strip()
        self.model_size = (model_size or "small").strip()
        self.compute_type = (compute_type or "int8").strip()
        self.language = (language or "zh").strip()
        self.local_files_only = local_files_only
        self.chunk_count = 0
        self.byte_count = 0
        self.container_extension = "webm"

    def push_chunk(self, payload: bytes, *, mime_type: str = "") -> TranscriptDelta:
        raw = payload or b""
        self._buffer.extend(raw)
        self.chunk_count += 1
        self.byte_count += len(raw)
        self._update_container_extension(mime_type)
        speaker = self.speaker_name or self.speaker_identity or "Speaker"
        return TranscriptDelta(
            message_type="partial_transcript",
            text=f"{speaker} audio buffered: {self.chunk_count} chunks / {self.byte_count} bytes",
            chunk_count=self.chunk_count,
            byte_count=self.byte_count,
        )

    def finalize(self) -> TranscriptDelta:
        if not self._buffer:
            return TranscriptDelta(
                message_type="final_transcript",
                text=f"",
                chunk_count=self.chunk_count,
                byte_count=self.byte_count,
            )

        model = self._get_model()
        with NamedTemporaryFile(suffix=f".{self.container_extension}", delete=True) as temp_audio:
            temp_audio.write(bytes(self._buffer))
            temp_audio.flush()
            segments, _info = model.transcribe(
                temp_audio.name,
                language=self.language,
                vad_filter=False,
            )
        text = " ".join((segment.text or "").strip() for segment in segments).strip()
        return TranscriptDelta(
            message_type="final_transcript",
            text=text,
            chunk_count=self.chunk_count,
            byte_count=self.byte_count,
        )

    def _get_model(self) -> WhisperModel:
        key = (self.model_size, self.compute_type)
        model = self._model_cache.get(key)
        if model is None:
            model = WhisperModel(
                self.model_size,
                device="cpu",
                compute_type=self.compute_type,
                cpu_threads=4,
                local_files_only=self.local_files_only,
            )
            self._model_cache[key] = model
        return model

    def _update_container_extension(self, mime_type: str) -> None:
        normalized = (mime_type or "").strip().lower()
        if "webm" in normalized:
            self.container_extension = "webm"
        elif "wav" in normalized:
            self.container_extension = "wav"
        elif "mpeg" in normalized or "mp3" in normalized:
            self.container_extension = "mp3"
        elif "ogg" in normalized:
            self.container_extension = "ogg"
        elif "aiff" in normalized or "aif" in normalized:
            self.container_extension = "aiff"
        elif "mp4" in normalized or "aac" in normalized:
            self.container_extension = "mp4"
