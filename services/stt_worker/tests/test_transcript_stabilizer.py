import unittest

from services.stt_worker.stt_worker.pipeline.transcript_stabilizer import (
    StabilizedTranscript,
    TranscriptStabilizer,
)


class TranscriptStabilizerTests(unittest.TestCase):
    def test_first_result_is_exposed_as_unstable_partial(self):
        stabilizer = TranscriptStabilizer()

        result = stabilizer.update("hello world")

        self.assertEqual(
            result,
            StabilizedTranscript(
                stable_prefix="",
                unstable_suffix="hello world",
                combined_text="hello world",
                stable_delta="",
                should_emit=True,
            ),
        )

    def test_growing_common_prefix_is_promoted_to_stable_delta(self):
        stabilizer = TranscriptStabilizer()
        stabilizer.update("hello wor")

        result = stabilizer.update("hello world and more")

        self.assertEqual(result.stable_prefix, "hello wor")
        self.assertEqual(result.unstable_suffix, "ld and more")
        self.assertEqual(result.stable_delta, "hello wor")
        self.assertTrue(result.should_emit)

    def test_same_text_twice_does_not_emit_again(self):
        stabilizer = TranscriptStabilizer()
        stabilizer.update("stable text")

        result = stabilizer.update("stable text")

        self.assertFalse(result.should_emit)
        self.assertEqual(result.combined_text, "stable text")

    def test_reset_clears_previous_state(self):
        stabilizer = TranscriptStabilizer()
        stabilizer.update("before reset")

        stabilizer.reset()
        result = stabilizer.update("after reset")

        self.assertEqual(result.stable_prefix, "")
        self.assertEqual(result.unstable_suffix, "after reset")
        self.assertTrue(result.should_emit)


if __name__ == "__main__":
    unittest.main()
