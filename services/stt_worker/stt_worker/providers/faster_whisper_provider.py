import io
import re
import wave
from tempfile import NamedTemporaryFile

from faster_whisper import WhisperModel

from services.stt_worker.stt_worker.providers.base import RealtimeTranscriptionProvider
from services.stt_worker.stt_worker.schemas import TranscriptDelta


def pcm16le_bytes_to_wav_bytes(
    pcm_bytes: bytes,
    *,
    sample_rate: int = 16000,
    channels: int = 1,
) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav_file:
        wav_file.setnchannels(max(1, int(channels or 1)))
        wav_file.setsampwidth(2)
        wav_file.setframerate(max(1, int(sample_rate or 16000)))
        wav_file.writeframes(pcm_bytes or b"")
    return output.getvalue()


def _infer_pcm_audio_config_from_mime_type(mime_type: str) -> tuple[int | None, int | None]:
    normalized = str(mime_type or "").strip().lower()
    if "audio/pcm" not in normalized:
        return None, None
    sample_rate_match = re.search(r"(?:^|[;,\s])(rate|sample_rate)=([0-9]{4,6})", normalized)
    channels_match = re.search(r"(?:^|[;,\s])(channels|channel_count)=([1-9])", normalized)
    sample_rate = int(sample_rate_match.group(2)) if sample_rate_match else None
    channels = int(channels_match.group(2)) if channels_match else None
    return sample_rate, channels


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
        self._last_transcript_text: str | None = None
        self.speaker_name = (speaker_name or "").strip()
        self.speaker_identity = (speaker_identity or "").strip()
        self.model_size = (model_size or "small").strip()
        self.compute_type = (compute_type or "int8").strip()
        self.language = (language or "zh").strip()
        self.local_files_only = local_files_only
        self.chunk_count = 0
        self.byte_count = 0
        self.container_extension = "webm"
        self.sample_rate = 16000
        self.channels = 1
        self._pcm_input = False

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

    def decode_partial(self, audio_window: bytes | None = None) -> str:
        audio_bytes = bytes(audio_window) if audio_window is not None else bytes(self._buffer)
        if not audio_bytes:
            return ""
        text = self._transcribe_audio_bytes(audio_bytes)
        self._last_transcript_text = text
        return text

    def finalize(self) -> TranscriptDelta:
        if not self._buffer:
            return TranscriptDelta(
                message_type="final_transcript",
                text=f"",
                chunk_count=self.chunk_count,
                byte_count=self.byte_count,
            )

        text = self._last_transcript_text
        if text is None:
            text = self._transcribe_audio_bytes(bytes(self._buffer))
            self._last_transcript_text = text
        return TranscriptDelta(
            message_type="final_transcript",
            text=text,
            chunk_count=self.chunk_count,
            byte_count=self.byte_count,
        )

    def _transcribe_audio_bytes(self, raw_audio_bytes: bytes) -> str:
        model = self._get_model()
        audio_bytes = raw_audio_bytes
        if self._pcm_input:
            audio_bytes = pcm16le_bytes_to_wav_bytes(
                audio_bytes,
                sample_rate=self.sample_rate,
                channels=self.channels,
            )
        with NamedTemporaryFile(suffix=f".{self.container_extension}", delete=True) as temp_audio:
            temp_audio.write(audio_bytes)
            temp_audio.flush()
            segments, _info = model.transcribe(
                temp_audio.name,
                language=self.language,
                vad_filter=False,
            )
        return " ".join((segment.text or "").strip() for segment in segments).strip()

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
        is_pcm = "audio/pcm" in normalized
        pcm_sample_rate, pcm_channels = _infer_pcm_audio_config_from_mime_type(normalized)
        if is_pcm:
            self._pcm_input = True
            self.sample_rate = int(pcm_sample_rate or self.sample_rate or 16000)
            self.channels = int(pcm_channels or self.channels or 1)
            self.container_extension = "wav"
        elif "webm" in normalized:
            self._pcm_input = False
            self.container_extension = "webm"
        elif "wav" in normalized:
            self._pcm_input = False
            self.container_extension = "wav"
        elif "mpeg" in normalized or "mp3" in normalized:
            self._pcm_input = False
            self.container_extension = "mp3"
        elif "ogg" in normalized:
            self._pcm_input = False
            self.container_extension = "ogg"
        elif "aiff" in normalized or "aif" in normalized:
            self._pcm_input = False
            self.container_extension = "aiff"
        elif "mp4" in normalized or "aac" in normalized:
            self._pcm_input = False
            self.container_extension = "mp4"
