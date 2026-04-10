import asyncio
import base64
import json
import unittest

import websockets

from services.stt_worker.stt_worker.config import SttWorkerConfig
from services.stt_worker.stt_worker.server import DEFAULT_WS_PATH, start_server


class RealtimeSttServerTests(unittest.IsolatedAsyncioTestCase):
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
        self.base_url = f"ws://127.0.0.1:{self.port}{DEFAULT_WS_PATH}"

    async def asyncTearDown(self):
        self.server.close()
        await self.server.wait_closed()

    async def test_server_emits_partial_and_final_transcript(self):
        async with websockets.connect(self.base_url) as websocket:
            await websocket.send(json.dumps({"type": "start", "speaker_name": "Owner", "speaker_identity": "owner-1"}))
            started = json.loads(await websocket.recv())
            await websocket.send(
                json.dumps(
                    {
                        "type": "audio_chunk",
                        "mime_type": "audio/webm",
                        "data_base64": base64.b64encode(b"abc").decode("ascii"),
                    }
                )
            )
            partial = json.loads(await websocket.recv())
            await websocket.send(json.dumps({"type": "stop"}))
            final = json.loads(await websocket.recv())

        self.assertEqual(started["type"], "session_started")
        self.assertEqual(started["provider"], "mock")
        self.assertEqual(partial["type"], "partial_transcript")
        self.assertEqual(partial["chunk_count"], 1)
        self.assertEqual(partial["byte_count"], 3)
        self.assertEqual(final["type"], "final_transcript")
        self.assertEqual(final["speaker_name"], "Owner")
        self.assertEqual(final["speaker_identity"], "owner-1")

    async def test_server_returns_error_for_invalid_json(self):
        async with websockets.connect(self.base_url) as websocket:
            await websocket.send("{not-json")
            response = json.loads(await websocket.recv())

        self.assertEqual(response["type"], "error")
        self.assertIn("json", response["detail"].lower())

    async def test_server_rejects_audio_before_start(self):
        async with websockets.connect(self.base_url) as websocket:
            await websocket.send(
                json.dumps(
                    {
                        "type": "audio_chunk",
                        "mime_type": "audio/webm",
                        "data_base64": base64.b64encode(b"abc").decode("ascii"),
                    }
                )
            )
            response = json.loads(await websocket.recv())

        self.assertEqual(response["type"], "error")
        self.assertIn("session", response["detail"].lower())


if __name__ == "__main__":
    unittest.main()
