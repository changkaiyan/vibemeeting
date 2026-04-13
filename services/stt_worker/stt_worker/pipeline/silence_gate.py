class SilenceGate:
    def __init__(
        self,
        *,
        rms_threshold: float = 0.02,
        trailing_silence_ms: int = 1000,
    ):
        self.rms_threshold = max(0.0, float(rms_threshold))
        self.finalize_silence_ms = max(0, int(trailing_silence_ms))
        self.speech_active = False
        self.trailing_silence_ms = 0
        self.should_finalize_turn = False

    def observe(self, *, rms: float, frame_ms: int) -> None:
        current_rms = max(0.0, float(rms))
        current_frame_ms = max(0, int(frame_ms))
        if current_rms >= self.rms_threshold:
            self.speech_active = True
            self.trailing_silence_ms = 0
            self.should_finalize_turn = False
            return
        if not self.speech_active:
            self.should_finalize_turn = False
            return
        self.trailing_silence_ms += current_frame_ms
        self.should_finalize_turn = self.trailing_silence_ms >= self.finalize_silence_ms

    def reset(self) -> None:
        self.speech_active = False
        self.trailing_silence_ms = 0
        self.should_finalize_turn = False
