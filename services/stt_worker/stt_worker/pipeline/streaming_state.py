class StreamingState:
    def __init__(
        self,
        *,
        decode_step_bytes: int = 6400 * 4,
        decode_overlap_bytes: int = 16000 * 2,
        rolling_window_bytes: int = 16000 * 2 * 6,
    ):
        self.decode_step_bytes = max(1, int(decode_step_bytes))
        self.decode_overlap_bytes = max(0, int(decode_overlap_bytes))
        self.rolling_window_bytes = max(1, int(rolling_window_bytes))
        self._buffer = bytearray()
        self._pending_decode_bytes = 0
        self.chunk_count = 0
        self.byte_count = 0
        self.total_audio_bytes = 0

    def append_chunk(self, payload: bytes) -> None:
        raw = payload or b""
        self._buffer.extend(raw)
        self._pending_decode_bytes += len(raw)
        self.chunk_count += 1
        self.byte_count += len(raw)
        self.total_audio_bytes += len(raw)

    def should_decode(self) -> bool:
        return self._pending_decode_bytes >= self.decode_step_bytes

    def buffered_audio(self) -> bytes:
        return bytes(self._buffer)

    def mark_decoded(self) -> bytes:
        if len(self._buffer) > self.rolling_window_bytes:
            self._buffer = self._buffer[-self.rolling_window_bytes :]
        decode_window_size = min(
            len(self._buffer),
            self._pending_decode_bytes + self.decode_overlap_bytes,
        )
        decode_window = bytes(self._buffer[-decode_window_size:]) if decode_window_size > 0 else b""
        self._pending_decode_bytes = 0
        return decode_window

    def reset(self) -> None:
        self._buffer = bytearray()
        self._pending_decode_bytes = 0
        self.chunk_count = 0
        self.byte_count = 0
        self.total_audio_bytes = 0
