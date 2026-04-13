import unittest

from services.stt_worker.stt_worker.pipeline.silence_gate import SilenceGate


class SilenceGateTests(unittest.TestCase):
    def test_marks_speech_active_when_rms_crosses_threshold(self):
        gate = SilenceGate(rms_threshold=0.02, trailing_silence_ms=1000)

        gate.observe(rms=0.03, frame_ms=200)

        self.assertTrue(gate.speech_active)
        self.assertEqual(gate.trailing_silence_ms, 0)

    def test_accumulates_trailing_silence_after_speech(self):
        gate = SilenceGate(rms_threshold=0.02, trailing_silence_ms=1000)
        gate.observe(rms=0.03, frame_ms=200)

        gate.observe(rms=0.0, frame_ms=200)
        gate.observe(rms=0.0, frame_ms=300)

        self.assertTrue(gate.speech_active)
        self.assertEqual(gate.trailing_silence_ms, 500)

    def test_finalize_turn_becomes_true_after_configured_silence_window(self):
        gate = SilenceGate(rms_threshold=0.02, trailing_silence_ms=900)
        gate.observe(rms=0.03, frame_ms=200)

        gate.observe(rms=0.0, frame_ms=400)
        gate.observe(rms=0.0, frame_ms=500)

        self.assertTrue(gate.should_finalize_turn)

    def test_reset_clears_speech_state(self):
        gate = SilenceGate(rms_threshold=0.02, trailing_silence_ms=900)
        gate.observe(rms=0.03, frame_ms=200)
        gate.observe(rms=0.0, frame_ms=900)

        gate.reset()

        self.assertFalse(gate.speech_active)
        self.assertFalse(gate.should_finalize_turn)
        self.assertEqual(gate.trailing_silence_ms, 0)


if __name__ == "__main__":
    unittest.main()
