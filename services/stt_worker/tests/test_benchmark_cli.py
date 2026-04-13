import json
import os
import sys
import asyncio
import unittest
from pathlib import Path

from services.stt_worker.stt_worker.config import SttWorkerConfig
from services.stt_worker.stt_worker.server import DEFAULT_WS_PATH
from services.stt_worker.stt_worker.server import start_server


class BenchmarkCliIntegrationTests(unittest.IsolatedAsyncioTestCase):
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
        self.repo_root = Path(__file__).resolve().parents[3]

    async def asyncTearDown(self):
        self.server.close()
        await self.server.wait_closed()

    async def test_cli_script_runs_against_mock_worker(self):
        env = os.environ.copy()
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
            env.pop(key, None)

        process = await asyncio.create_subprocess_exec(
            sys.executable,
            "scripts/stt_benchmark.py",
            "--url",
            self.url,
            "--iterations",
            "1",
            "--concurrency",
            "1",
            "--chunk-ms",
            "200",
            "--speech-duration-ms",
            "400",
            "--trailing-silence-ms",
            "400",
            cwd=str(self.repo_root),
            env=env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await process.communicate()

        self.assertEqual(process.returncode, 0, msg=stderr.decode("utf-8"))
        payload = json.loads(stdout.decode("utf-8"))
        self.assertEqual(payload["summary"]["total_sessions"], 1)
        self.assertEqual(payload["summary"]["successful_sessions"], 1)
