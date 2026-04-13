import unittest

from services.stt_worker.stt_worker.benchmark import BenchmarkConfig
from services.stt_worker.stt_worker.benchmark import run_benchmark
from services.stt_worker.stt_worker.config import SttWorkerConfig
from services.stt_worker.stt_worker.server import DEFAULT_WS_PATH
from services.stt_worker.stt_worker.server import start_server


class BenchmarkRunnerIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.server = await start_server(
            SttWorkerConfig(
                host="127.0.0.1",
                port=0,
                provider="mock",
            )
        )
        socket = self.server.sockets[0]
        self.port = socket.getsockname()[1]
        self.url = f"ws://127.0.0.1:{self.port}{DEFAULT_WS_PATH}"

    async def asyncTearDown(self):
        self.server.close()
        await self.server.wait_closed()

    async def test_run_benchmark_reports_partial_and_final_latencies(self):
        result = await run_benchmark(
            BenchmarkConfig(
                url=self.url,
                concurrency=1,
                iterations=1,
                chunk_ms=200,
                speech_duration_ms=400,
                trailing_silence_ms=400,
                sample_rate=16000,
            )
        )

        self.assertEqual(result.summary.total_sessions, 1)
        self.assertEqual(result.summary.successful_sessions, 1)
        self.assertGreater(result.summary.bytes_per_second, 0.0)
        self.assertEqual(len(result.sessions), 1)

        session = result.sessions[0]
        self.assertTrue(session.ok)
        self.assertEqual(session.sent_chunks, 4)
        self.assertGreater(session.sent_bytes, 0)
        self.assertIsNotNone(session.first_partial_latency_ms)
        self.assertIsNotNone(session.final_latency_ms)
        self.assertGreaterEqual(session.final_latency_ms, session.first_partial_latency_ms)
