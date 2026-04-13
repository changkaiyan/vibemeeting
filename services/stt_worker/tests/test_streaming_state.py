import unittest

from services.stt_worker.stt_worker.pipeline.streaming_state import StreamingState


class StreamingStateTests(unittest.TestCase):
    def test_append_chunk_accumulates_bytes_and_chunk_count(self):
        state = StreamingState()

        state.append_chunk(b"abc")
        state.append_chunk(b"defg")

        self.assertEqual(state.chunk_count, 2)
        self.assertEqual(state.byte_count, 7)
        self.assertEqual(state.total_audio_bytes, 7)

    def test_decode_becomes_due_after_minimum_pending_bytes(self):
        state = StreamingState(decode_step_bytes=6)

        state.append_chunk(b"abc")
        self.assertFalse(state.should_decode())

        state.append_chunk(b"def")
        self.assertTrue(state.should_decode())

    def test_mark_decoded_resets_pending_decode_bytes(self):
        state = StreamingState(decode_step_bytes=6)
        state.append_chunk(b"abcdef")

        window = state.mark_decoded()

        self.assertEqual(window, b"abcdef")
        self.assertFalse(state.should_decode())

    def test_mark_decoded_keeps_only_rolling_window_tail(self):
        state = StreamingState(decode_step_bytes=4, rolling_window_bytes=5)
        state.append_chunk(b"abc")
        state.append_chunk(b"def")

        window = state.mark_decoded()

        self.assertEqual(window, b"bcdef")
        self.assertEqual(state.buffered_audio(), b"bcdef")

    def test_mark_decoded_returns_overlap_plus_pending_window_instead_of_full_buffer(self):
        state = StreamingState(
            decode_step_bytes=4,
            decode_overlap_bytes=2,
            rolling_window_bytes=16,
        )
        state.append_chunk(b"abcd")
        first_window = state.mark_decoded()

        state.append_chunk(b"efgh")
        second_window = state.mark_decoded()

        self.assertEqual(first_window, b"abcd")
        self.assertEqual(second_window, b"cdefgh")

    def test_reset_clears_state(self):
        state = StreamingState(decode_step_bytes=4, rolling_window_bytes=5)
        state.append_chunk(b"abcdef")
        state.mark_decoded()

        state.reset()

        self.assertEqual(state.chunk_count, 0)
        self.assertEqual(state.byte_count, 0)
        self.assertEqual(state.total_audio_bytes, 0)
        self.assertEqual(state.buffered_audio(), b"")
        self.assertFalse(state.should_decode())


if __name__ == "__main__":
    unittest.main()
