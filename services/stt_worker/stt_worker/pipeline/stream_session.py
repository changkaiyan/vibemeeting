from services.stt_worker.stt_worker.config import SttWorkerConfig
from services.stt_worker.stt_worker.pipeline.silence_gate import SilenceGate
from services.stt_worker.stt_worker.pipeline.streaming_state import StreamingState
from services.stt_worker.stt_worker.pipeline.transcript_stabilizer import TranscriptStabilizer
from services.stt_worker.stt_worker.schemas import TranscriptDelta
from services.stt_worker.stt_worker.providers.faster_whisper_provider import (
    FasterWhisperRealtimeProvider,
)
from services.stt_worker.stt_worker.providers.volcengine_realtime_provider import (
    VolcengineRealtimeProvider,
)


class MockRealtimeTranscriptionSession:
    def __init__(
        self,
        *,
        speaker_name: str = "",
        speaker_identity: str = "",
        decode_step_bytes: int = 1024,
    ):
        self.speaker_name = (speaker_name or "").strip()
        self.speaker_identity = (speaker_identity or "").strip()
        self._state = StreamingState(decode_step_bytes=decode_step_bytes)
        self._stabilizer = TranscriptStabilizer()
        self._last_partial_text = ""

    def push_chunk(self, payload: bytes, *, mime_type: str = "") -> TranscriptDelta:
        raw = payload or b""
        self._state.append_chunk(raw)
        speaker = self.speaker_name or self.speaker_identity or "Speaker"
        if not self._state.should_decode():
            return TranscriptDelta(
                message_type="partial_transcript",
                text=f"{speaker} waiting for more audio... {self._state.byte_count} bytes buffered",
                chunk_count=self._state.chunk_count,
                byte_count=self._state.byte_count,
            )
        window = self._state.mark_decoded()
        decoded_text = (
            f"{speaker} partial transcript: "
            f"{self._state.chunk_count} chunks / {self._state.byte_count} bytes"
        )
        stabilized = self._stabilizer.update(decoded_text)
        self._last_partial_text = stabilized.combined_text
        return TranscriptDelta(
            message_type="partial_transcript",
            text=stabilized.combined_text if window else decoded_text,
            chunk_count=self._state.chunk_count,
            byte_count=self._state.byte_count,
        )

    def finalize(self) -> TranscriptDelta:
        speaker = self.speaker_name or self.speaker_identity or "Speaker"
        text = self._last_partial_text or (
            f"Mock realtime transcript for {speaker}: "
            f"{self._state.chunk_count} chunks, {self._state.byte_count} bytes received."
        )
        return TranscriptDelta(
            message_type="final_transcript",
            text=text,
            chunk_count=self._state.chunk_count,
            byte_count=self._state.byte_count,
        )

    def decode_partial(self, audio_window: bytes | None = None) -> str:
        return self._last_partial_text


class ProviderRealtimeSession:
    def __init__(
        self,
        provider,
        *,
        decode_step_bytes: int = 1024,
        decode_overlap_bytes: int = 16000 * 2,
        trailing_silence_ms: int = 1000,
        rms_threshold: float = 0.02,
    ):
        self._provider = provider
        self._state = StreamingState(
            decode_step_bytes=decode_step_bytes,
            decode_overlap_bytes=decode_overlap_bytes,
        )
        self._stabilizer = TranscriptStabilizer()
        self._silence_gate = SilenceGate(
            rms_threshold=rms_threshold,
            trailing_silence_ms=trailing_silence_ms,
        )

    def push_chunk(self, payload: bytes, *, mime_type: str = "") -> TranscriptDelta:
        delta = self._provider.push_chunk(payload, mime_type=mime_type)
        raw = payload or b""
        self._state.append_chunk(raw)
        frame_ms = _pcm_frame_duration_ms(raw, mime_type=mime_type)
        if frame_ms > 0:
            self._silence_gate.observe(
                rms=_pcm16_rms(raw),
                frame_ms=frame_ms,
            )
        if not self._state.should_decode():
            if self._silence_gate.should_finalize_turn:
                final = self._provider.finalize()
                self._reset_segment_state()
                return final
            return TranscriptDelta(
                message_type="partial_transcript",
                text=f"Waiting for more audio... {self._state.byte_count} bytes buffered",
                chunk_count=delta.chunk_count,
                byte_count=delta.byte_count,
            )
        decode_window = self._state.mark_decoded()
        partial_text = self._provider.decode_partial(decode_window)
        stabilized = self._stabilizer.update(partial_text)
        if self._silence_gate.should_finalize_turn:
            final = self._provider.finalize()
            self._reset_segment_state()
            return final
        return TranscriptDelta(
            message_type="partial_transcript",
            text=stabilized.combined_text,
            chunk_count=delta.chunk_count,
            byte_count=delta.byte_count,
        )

    def finalize(self) -> TranscriptDelta:
        return self._provider.finalize()

    def decode_partial(self, audio_window: bytes | None = None) -> str:
        return self._provider.decode_partial(audio_window)

    def _reset_segment_state(self) -> None:
        self._state.reset()
        self._stabilizer.reset()
        self._silence_gate.reset()


def build_realtime_session(
    config: SttWorkerConfig,
    *,
    speaker_name: str = "",
    speaker_identity: str = "",
    decode_step_bytes: int = 1024,
    decode_overlap_bytes: int = 16000 * 2,
    trailing_silence_ms: int = 1000,
):
    provider = (config.provider or "mock").strip().lower()
    if provider == "mock":
        return MockRealtimeTranscriptionSession(
            speaker_name=speaker_name,
            speaker_identity=speaker_identity,
        )
    if provider == "faster_whisper":
        provider_instance = FasterWhisperRealtimeProvider(
            speaker_name=speaker_name,
            speaker_identity=speaker_identity,
            model_size=config.model_size,
            compute_type=config.compute_type,
            language=config.language,
            local_files_only=config.local_files_only,
        )
        return ProviderRealtimeSession(
            provider_instance,
            decode_step_bytes=decode_step_bytes,
            decode_overlap_bytes=decode_overlap_bytes,
            trailing_silence_ms=trailing_silence_ms,
        )
    if provider == "volcengine_realtime":
        return VolcengineRealtimeProvider(
            appid=config.volcengine_app_id,
            access_token=config.volcengine_access_token,
            resource_id=config.volcengine_resource_id,
            ws_url=config.volcengine_ws_url,
            speaker_name=speaker_name,
            speaker_identity=speaker_identity,
        )
    raise ValueError(f"Unsupported STT worker provider: {config.provider}")


def _pcm16_rms(payload: bytes) -> float:
    raw = payload[: len(payload) - (len(payload) % 2)]
    if not raw:
        return 0.0
    total = 0.0
    count = 0
    for index in range(0, len(raw), 2):
        sample = int.from_bytes(raw[index : index + 2], "little", signed=True) / 32768.0
        total += sample * sample
        count += 1
    if count == 0:
        return 0.0
    return (total / count) ** 0.5


def _pcm_frame_duration_ms(payload: bytes, *, mime_type: str) -> int:
    normalized = (mime_type or "").strip().lower()
    if "audio/pcm" not in normalized:
        return 0
    sample_rate = 16000
    for part in normalized.split(";"):
        item = part.strip()
        if item.startswith("rate="):
            try:
                sample_rate = max(1, int(item.split("=", 1)[1]))
            except ValueError:
                sample_rate = 16000
    sample_count = len(payload[: len(payload) - (len(payload) % 2)]) // 2
    if sample_count <= 0:
        return 0
    return int(sample_count * 1000 / sample_rate)
