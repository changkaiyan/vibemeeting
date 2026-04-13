import unittest

from services.stt_worker.stt_worker.benchmark import BenchmarkConfig
from services.stt_worker.stt_worker.benchmark import BenchmarkSessionResult
from services.stt_worker.stt_worker.benchmark import build_pcm16_chunk_plan
from services.stt_worker.stt_worker.benchmark import summarize_results


class BenchmarkChunkPlanTests(unittest.TestCase):
    def test_build_pcm16_chunk_plan_splits_audio_into_equal_chunks(self):
        plan = build_pcm16_chunk_plan(
            sample_rate=16000,
            chunk_ms=200,
            speech_duration_ms=600,
            trailing_silence_ms=400,
            amplitude=1200,
        )

        self.assertEqual(len(plan), 5)
        self.assertTrue(all(chunk.mime_type == "audio/pcm;rate=16000;channels=1" for chunk in plan))
        self.assertEqual([len(chunk.payload) for chunk in plan], [6400, 6400, 6400, 6400, 6400])
        self.assertNotEqual(plan[0].payload, b"\x00\x00" * 3200)
        self.assertEqual(plan[-1].payload, b"\x00\x00" * 3200)

    def test_build_pcm16_chunk_plan_rejects_invalid_chunk_size(self):
        with self.assertRaises(ValueError):
            build_pcm16_chunk_plan(
                sample_rate=16000,
                chunk_ms=0,
                speech_duration_ms=600,
                trailing_silence_ms=400,
            )


class BenchmarkSummaryTests(unittest.TestCase):
    def test_summarize_results_computes_latency_percentiles_and_success_rate(self):
        summary = summarize_results(
            [
                BenchmarkSessionResult(
                    ok=True,
                    sent_chunks=5,
                    sent_bytes=32000,
                    first_partial_latency_ms=120.0,
                    final_latency_ms=950.0,
                    wall_time_ms=1000.0,
                    error="",
                ),
                BenchmarkSessionResult(
                    ok=True,
                    sent_chunks=5,
                    sent_bytes=32000,
                    first_partial_latency_ms=180.0,
                    final_latency_ms=1100.0,
                    wall_time_ms=1200.0,
                    error="",
                ),
                BenchmarkSessionResult(
                    ok=False,
                    sent_chunks=2,
                    sent_bytes=12800,
                    first_partial_latency_ms=None,
                    final_latency_ms=None,
                    wall_time_ms=300.0,
                    error="timeout",
                ),
            ]
        )

        self.assertEqual(summary.total_sessions, 3)
        self.assertEqual(summary.successful_sessions, 2)
        self.assertAlmostEqual(summary.success_rate, 2 / 3, places=4)
        self.assertEqual(summary.first_partial_p50_ms, 150.0)
        self.assertEqual(summary.first_partial_p95_ms, 177.0)
        self.assertEqual(summary.final_p50_ms, 1025.0)
        self.assertEqual(summary.final_p95_ms, 1092.5)
        self.assertEqual(summary.error_counts, {"timeout": 1})

    def test_benchmark_config_validates_concurrency(self):
        with self.assertRaises(ValueError):
            BenchmarkConfig(url="ws://127.0.0.1:9001/ws/realtime-transcribe", concurrency=0)
