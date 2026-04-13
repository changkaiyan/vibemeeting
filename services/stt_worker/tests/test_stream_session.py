import unittest
from types import SimpleNamespace
from unittest.mock import patch

from services.stt_worker.stt_worker.config import SttWorkerConfig
from services.stt_worker.stt_worker.pipeline.stream_session import build_realtime_session
from services.stt_worker.stt_worker.pipeline.stream_session import MockRealtimeTranscriptionSession
from services.stt_worker.stt_worker.providers.faster_whisper_provider import (
    FasterWhisperRealtimeProvider,
    pcm16le_bytes_to_wav_bytes,
)
from services.stt_worker.stt_worker.providers.volcengine_realtime_provider import (
    VolcengineRealtimeProvider,
)
from services.stt_worker.stt_worker.schemas import TranscriptDelta


class MockRealtimeTranscriptionSessionTests(unittest.TestCase):
    def test_push_chunk_returns_partial_text(self):
        session = MockRealtimeTranscriptionSession(
            speaker_name="Owner",
            speaker_identity="owner-1",
            decode_step_bytes=1,
        )

        partial = session.push_chunk(b"abc")

        self.assertEqual(partial.message_type, "partial_transcript")
        self.assertIn("Owner", partial.text)
        self.assertEqual(partial.chunk_count, 1)
        self.assertEqual(partial.byte_count, 3)

    def test_push_chunk_below_decode_threshold_keeps_waiting_text(self):
        session = MockRealtimeTranscriptionSession(
            speaker_name="Owner",
            speaker_identity="owner-1",
            decode_step_bytes=10,
        )

        partial = session.push_chunk(b"abc")

        self.assertEqual(partial.message_type, "partial_transcript")
        self.assertIn("waiting", partial.text.lower())
        self.assertEqual(partial.chunk_count, 1)

    def test_push_chunk_promotes_partial_after_decode_threshold_is_reached(self):
        session = MockRealtimeTranscriptionSession(
            speaker_name="Owner",
            speaker_identity="owner-1",
            decode_step_bytes=5,
        )

        session.push_chunk(b"abc")
        second = session.push_chunk(b"de")

        self.assertEqual(second.message_type, "partial_transcript")
        self.assertIn("Owner", second.text)
        self.assertIn("5 bytes", second.text)

    def test_push_chunk_promotes_stable_prefix_across_updates(self):
        session = MockRealtimeTranscriptionSession(
            speaker_name="Owner",
            speaker_identity="owner-1",
            decode_step_bytes=1,
        )

        first = session.push_chunk(b"a" * 1200)
        second = session.push_chunk(b"b" * 1200)

        self.assertEqual(first.message_type, "partial_transcript")
        self.assertEqual(second.message_type, "partial_transcript")
        self.assertIn("Owner", second.text)
        self.assertGreaterEqual(second.chunk_count, 2)

    def test_finalize_returns_last_partial_text_when_available(self):
        session = MockRealtimeTranscriptionSession(speaker_name="Owner", speaker_identity="owner-1")
        session.push_chunk(b"abc")

        final = session.finalize()

        self.assertEqual(final.message_type, "final_transcript")
        self.assertIn("Owner", final.text)
        self.assertEqual(final.chunk_count, 1)
        self.assertEqual(final.byte_count, 3)

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

    def test_build_realtime_session_uses_volcengine_resource_id_settings(self):
        session = build_realtime_session(
            SttWorkerConfig(
                provider="volcengine_realtime",
                volcengine_app_id="app-123",
                volcengine_access_token="token-123",
                volcengine_resource_id="volc.bigasr.sauc.duration",
                volcengine_ws_url="wss://openspeech.bytedance.com/api/v3/sauc/bigmodel",
            ),
            speaker_name="Owner",
            speaker_identity="owner-1",
        )

        self.assertIsInstance(session, VolcengineRealtimeProvider)
        self.assertEqual(session.appid, "app-123")
        self.assertEqual(session.access_token, "token-123")
        self.assertEqual(session.resource_id, "volc.bigasr.sauc.duration")
        self.assertEqual(session.ws_url, "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")


class FasterWhisperRealtimeProviderTests(unittest.TestCase):
    def setUp(self):
        FasterWhisperRealtimeProvider._model_cache.clear()

    def test_pcm16le_bytes_to_wav_bytes_wraps_pcm_payload(self):
        wav_bytes = pcm16le_bytes_to_wav_bytes(
            b"\x01\x00\xff\x7f",
            sample_rate=16000,
            channels=1,
        )

        self.assertTrue(wav_bytes.startswith(b"RIFF"))
        self.assertIn(b"WAVE", wav_bytes[:16])
        self.assertEqual(wav_bytes[24:28], (16000).to_bytes(4, "little"))
        self.assertEqual(wav_bytes[40:44], (4).to_bytes(4, "little"))
        self.assertEqual(wav_bytes[44:], b"\x01\x00\xff\x7f")

    def test_push_chunk_buffers_audio_and_returns_partial(self):
        provider = FasterWhisperRealtimeProvider(speaker_name="Owner", speaker_identity="owner-1")

        partial = provider.push_chunk(b"abc", mime_type="audio/webm")

        self.assertEqual(partial.message_type, "partial_transcript")
        self.assertIn("Owner", partial.text)
        self.assertEqual(partial.chunk_count, 1)
        self.assertEqual(partial.byte_count, 3)

    def test_push_chunk_tracks_pcm_stream_metadata_from_mime_type(self):
        provider = FasterWhisperRealtimeProvider(speaker_name="Owner", speaker_identity="owner-1")

        provider.push_chunk(b"\x01\x00\x02\x00", mime_type="audio/pcm;rate=8000;channels=2")

        self.assertEqual(provider.container_extension, "wav")
        self.assertEqual(provider.sample_rate, 8000)
        self.assertEqual(provider.channels, 2)

    @patch("services.stt_worker.stt_worker.providers.faster_whisper_provider.WhisperModel")
    def test_decode_partial_transcribes_current_buffer(self, mock_model_cls):
        segment_1 = SimpleNamespace(text="实时")
        segment_2 = SimpleNamespace(text="字幕")
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

        partial_text = provider.decode_partial()

        self.assertEqual(partial_text, "实时 字幕")
        mock_model.transcribe.assert_called_once()

    @patch("services.stt_worker.stt_worker.providers.faster_whisper_provider.WhisperModel")
    def test_decode_partial_wraps_pcm_input_as_wav_before_transcribe(self, mock_model_cls):
        mock_model = mock_model_cls.return_value
        mock_model.transcribe.return_value = (iter([SimpleNamespace(text="pcm partial")]), SimpleNamespace(language="zh"))
        provider = FasterWhisperRealtimeProvider(
            speaker_name="Owner",
            speaker_identity="owner-1",
            model_size="tiny",
            compute_type="int8",
            language="zh",
            local_files_only=False,
        )
        provider.push_chunk(b"\x01\x00\x02\x00", mime_type="audio/pcm;rate=16000")

        partial_text = provider.decode_partial()

        self.assertEqual(partial_text, "pcm partial")
        transcribe_call = mock_model.transcribe.call_args
        self.assertIsNotNone(transcribe_call)
        partial_path = transcribe_call.args[0]
        self.assertTrue(str(partial_path).endswith(".wav"))

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
    def test_finalize_reuses_cached_partial_transcript_without_retranscribing(self, mock_model_cls):
        mock_model = mock_model_cls.return_value
        mock_model.transcribe.return_value = (
            iter([SimpleNamespace(text="你好"), SimpleNamespace(text="世界")]),
            SimpleNamespace(language="zh"),
        )
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

        partial_text = provider.decode_partial()
        final = provider.finalize()

        self.assertEqual(partial_text, "你好 世界")
        self.assertEqual(final.text, "你好 世界")
        mock_model.transcribe.assert_called_once()

    @patch("services.stt_worker.stt_worker.providers.faster_whisper_provider.WhisperModel")
    def test_build_realtime_session_can_return_faster_whisper_provider(self, mock_model_cls):
        provider = build_realtime_session(
            SttWorkerConfig(provider="faster_whisper", model_size="tiny", compute_type="int8"),
            speaker_name="Owner",
            speaker_identity="owner-1",
        )

        self.assertTrue(hasattr(provider, "push_chunk"))
        self.assertTrue(hasattr(provider, "finalize"))

    @patch("services.stt_worker.stt_worker.pipeline.stream_session.FasterWhisperRealtimeProvider")
    def test_faster_whisper_session_waits_until_decode_threshold_before_partial_decode(
        self,
        mock_provider_cls,
    ):
        provider = mock_provider_cls.return_value
        provider.push_chunk.return_value = TranscriptDelta(
            message_type="partial_transcript",
            text="buffered",
            chunk_count=1,
            byte_count=3,
        )
        provider.decode_partial.return_value = "decoded partial"
        provider.finalize.return_value = TranscriptDelta(
            message_type="final_transcript",
            text="decoded final",
            chunk_count=1,
            byte_count=3,
        )

        session = build_realtime_session(
            SttWorkerConfig(provider="faster_whisper", model_size="tiny", compute_type="int8"),
            speaker_name="Owner",
            speaker_identity="owner-1",
            decode_step_bytes=10,
        )

        partial = session.push_chunk(b"abc", mime_type="audio/pcm;rate=16000")

        self.assertEqual(partial.message_type, "partial_transcript")
        self.assertIn("waiting", partial.text.lower())
        provider.decode_partial.assert_not_called()

    @patch("services.stt_worker.stt_worker.pipeline.stream_session.FasterWhisperRealtimeProvider")
    def test_faster_whisper_session_decodes_partial_when_threshold_is_reached(
        self,
        mock_provider_cls,
    ):
        provider = mock_provider_cls.return_value
        provider.push_chunk.side_effect = [
            TranscriptDelta(message_type="partial_transcript", text="buffered-1", chunk_count=1, byte_count=3),
            TranscriptDelta(message_type="partial_transcript", text="buffered-2", chunk_count=2, byte_count=5),
        ]
        provider.decode_partial.return_value = "hello streaming world"
        provider.finalize.return_value = TranscriptDelta(
            message_type="final_transcript",
            text="hello streaming world",
            chunk_count=2,
            byte_count=5,
        )

        session = build_realtime_session(
            SttWorkerConfig(provider="faster_whisper", model_size="tiny", compute_type="int8"),
            speaker_name="Owner",
            speaker_identity="owner-1",
            decode_step_bytes=5,
        )

        session.push_chunk(b"abc", mime_type="audio/pcm;rate=16000")
        partial = session.push_chunk(b"de", mime_type="audio/pcm;rate=16000")

        self.assertEqual(partial.message_type, "partial_transcript")
        self.assertIn("hello streaming world", partial.text)
        provider.decode_partial.assert_called_once_with(b"abcde")

    @patch("services.stt_worker.stt_worker.pipeline.stream_session.FasterWhisperRealtimeProvider")
    def test_faster_whisper_session_decodes_only_recent_window_with_overlap(
        self,
        mock_provider_cls,
    ):
        provider = mock_provider_cls.return_value
        provider.push_chunk.side_effect = [
            TranscriptDelta(message_type="partial_transcript", text="buffered-1", chunk_count=1, byte_count=4),
            TranscriptDelta(message_type="partial_transcript", text="buffered-2", chunk_count=2, byte_count=8),
        ]
        provider.decode_partial.return_value = "window transcript"
        provider.finalize.return_value = TranscriptDelta(
            message_type="final_transcript",
            text="window transcript",
            chunk_count=2,
            byte_count=8,
        )

        session = build_realtime_session(
            SttWorkerConfig(provider="faster_whisper", model_size="tiny", compute_type="int8"),
            speaker_name="Owner",
            speaker_identity="owner-1",
            decode_step_bytes=4,
            decode_overlap_bytes=2,
        )

        session.push_chunk(b"abcd", mime_type="audio/pcm;rate=16000")
        session.push_chunk(b"efgh", mime_type="audio/pcm;rate=16000")

        self.assertEqual(provider.decode_partial.call_args_list[0].args[0], b"abcd")
        self.assertEqual(provider.decode_partial.call_args_list[1].args[0], b"cdefgh")

    @patch("services.stt_worker.stt_worker.pipeline.stream_session.FasterWhisperRealtimeProvider")
    def test_faster_whisper_session_auto_finalizes_after_pcm_trailing_silence(
        self,
        mock_provider_cls,
    ):
        provider = mock_provider_cls.return_value
        provider.push_chunk.side_effect = [
            TranscriptDelta(message_type="partial_transcript", text="buffered-1", chunk_count=1, byte_count=3200),
            TranscriptDelta(message_type="partial_transcript", text="buffered-2", chunk_count=2, byte_count=6400),
            TranscriptDelta(message_type="partial_transcript", text="buffered-3", chunk_count=3, byte_count=9600),
        ]
        provider.decode_partial.return_value = "active speech"
        provider.finalize.return_value = TranscriptDelta(
            message_type="final_transcript",
            text="active speech",
            chunk_count=3,
            byte_count=9600,
        )

        session = build_realtime_session(
            SttWorkerConfig(provider="faster_whisper", model_size="tiny", compute_type="int8"),
            speaker_name="Owner",
            speaker_identity="owner-1",
            decode_step_bytes=3200,
            trailing_silence_ms=400,
        )

        speech_chunk = (1000).to_bytes(2, "little", signed=True) * 1600
        silence_chunk = b"\x00\x00" * 6400

        first = session.push_chunk(speech_chunk, mime_type="audio/pcm;rate=16000")
        second = session.push_chunk(silence_chunk, mime_type="audio/pcm;rate=16000")

        self.assertEqual(first.message_type, "partial_transcript")
        self.assertEqual(second.message_type, "final_transcript")
        self.assertEqual(second.text, "active speech")
        provider.finalize.assert_called_once()

    @patch("services.stt_worker.stt_worker.pipeline.stream_session.FasterWhisperRealtimeProvider")
    def test_faster_whisper_session_finalize_reuses_last_partial_without_redecoding(
        self,
        mock_provider_cls,
    ):
        provider = mock_provider_cls.return_value
        provider.push_chunk.side_effect = [
            TranscriptDelta(message_type="partial_transcript", text="buffered-1", chunk_count=1, byte_count=3),
            TranscriptDelta(message_type="partial_transcript", text="buffered-2", chunk_count=2, byte_count=5),
        ]
        provider.decode_partial.return_value = "hello streaming world"
        provider.finalize.return_value = TranscriptDelta(
            message_type="final_transcript",
            text="hello streaming world",
            chunk_count=2,
            byte_count=5,
        )

        session = build_realtime_session(
            SttWorkerConfig(provider="faster_whisper", model_size="tiny", compute_type="int8"),
            speaker_name="Owner",
            speaker_identity="owner-1",
            decode_step_bytes=5,
        )

        session.push_chunk(b"abc", mime_type="audio/pcm;rate=16000")
        session.push_chunk(b"de", mime_type="audio/pcm;rate=16000")
        final = session.finalize()

        self.assertEqual(final.message_type, "final_transcript")
        self.assertEqual(final.text, "hello streaming world")
        provider.decode_partial.assert_called_once()
        provider.finalize.assert_called_once()


if __name__ == "__main__":
    unittest.main()
