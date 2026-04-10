import unittest
from types import SimpleNamespace
from unittest.mock import patch

from services.stt_worker.stt_worker.config import SttWorkerConfig
from services.stt_worker.stt_worker.pipeline.stream_session import build_realtime_session
from services.stt_worker.stt_worker.pipeline.stream_session import MockRealtimeTranscriptionSession
from services.stt_worker.stt_worker.providers.faster_whisper_provider import (
    FasterWhisperRealtimeProvider,
)


class MockRealtimeTranscriptionSessionTests(unittest.TestCase):
    def test_push_chunk_returns_partial_text(self):
        session = MockRealtimeTranscriptionSession(speaker_name="Owner", speaker_identity="owner-1")

        partial = session.push_chunk(b"abc")

        self.assertEqual(partial.message_type, "partial_transcript")
        self.assertIn("Owner", partial.text)
        self.assertEqual(partial.chunk_count, 1)
        self.assertEqual(partial.byte_count, 3)

    def test_finalize_returns_final_text(self):
        session = MockRealtimeTranscriptionSession(speaker_name="Owner", speaker_identity="owner-1")
        session.push_chunk(b"abc")
        session.push_chunk(b"defgh")

        final = session.finalize()

        self.assertEqual(final.message_type, "final_transcript")
        self.assertIn("Owner", final.text)
        self.assertEqual(final.chunk_count, 2)
        self.assertEqual(final.byte_count, 8)

    def test_build_realtime_session_uses_mock_provider(self):
        session = build_realtime_session(
            SttWorkerConfig(provider="mock"),
            speaker_name="Owner",
            speaker_identity="owner-1",
        )

        self.assertIsInstance(session, MockRealtimeTranscriptionSession)

    def test_build_realtime_session_rejects_unknown_provider(self):
        with self.assertRaises(ValueError):
            build_realtime_session(SttWorkerConfig(provider="unknown"))


class FasterWhisperRealtimeProviderTests(unittest.TestCase):
    def test_push_chunk_buffers_audio_and_returns_partial(self):
        provider = FasterWhisperRealtimeProvider(speaker_name="Owner", speaker_identity="owner-1")

        partial = provider.push_chunk(b"abc", mime_type="audio/webm")

        self.assertEqual(partial.message_type, "partial_transcript")
        self.assertIn("Owner", partial.text)
        self.assertEqual(partial.chunk_count, 1)
        self.assertEqual(partial.byte_count, 3)

    @patch("services.stt_worker.stt_worker.providers.faster_whisper_provider.WhisperModel")
    def test_finalize_transcribes_buffered_audio(self, mock_model_cls):
        segment_1 = SimpleNamespace(text="你好")
        segment_2 = SimpleNamespace(text="世界")
        mock_model = mock_model_cls.return_value
        mock_model.transcribe.return_value = (iter([segment_1, segment_2]), SimpleNamespace(language="zh"))
        provider = FasterWhisperRealtimeProvider(
            speaker_name="Owner",
            speaker_identity="owner-1",
            model_size="tiny",
            compute_type="int8",
            language="zh",
            local_files_only=False,
        )
        provider.push_chunk(b"abc", mime_type="audio/webm")
        provider.push_chunk(b"def", mime_type="audio/webm")

        final = provider.finalize()

        self.assertEqual(final.message_type, "final_transcript")
        self.assertEqual(final.text, "你好 世界")
        self.assertEqual(final.chunk_count, 2)
        self.assertEqual(final.byte_count, 6)
        mock_model_cls.assert_called_once_with(
            "tiny",
            device="cpu",
            compute_type="int8",
            cpu_threads=4,
            local_files_only=False,
        )
        mock_model.transcribe.assert_called_once()
        self.assertEqual(provider.container_extension, "webm")

    @patch("services.stt_worker.stt_worker.providers.faster_whisper_provider.WhisperModel")
    def test_build_realtime_session_can_return_faster_whisper_provider(self, mock_model_cls):
        provider = build_realtime_session(
            SttWorkerConfig(provider="faster_whisper", model_size="tiny", compute_type="int8"),
            speaker_name="Owner",
            speaker_identity="owner-1",
        )

        self.assertIsInstance(provider, FasterWhisperRealtimeProvider)


if __name__ == "__main__":
    unittest.main()
