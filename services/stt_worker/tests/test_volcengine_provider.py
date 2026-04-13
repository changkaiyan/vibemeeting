import json
import os
import gzip
import unittest
from unittest.mock import patch

from services.stt_worker.stt_worker.config import load_config
from services.stt_worker.stt_worker.providers.volcengine_realtime_provider import (
    OPENSPEECH_BIGMODEL_WS_URL,
    VolcengineRealtimeProvider,
    build_audio_only_request_frame,
    build_openspeech_auth_headers,
    build_openspeech_full_client_request_payload,
    parse_server_message,
)


class VolcengineRealtimeProviderHelpersTests(unittest.TestCase):
    def test_build_auth_headers_uses_x_api_headers(self):
        headers = build_openspeech_auth_headers(
            appid="app-123",
            access_token="token-123",
            resource_id="volc.bigasr.sauc.duration",
            connect_id="connect-123",
        )

        self.assertEqual(headers["X-Api-App-Key"], "app-123")
        self.assertEqual(headers["X-Api-Access-Key"], "token-123")
        self.assertEqual(headers["X-Api-Resource-Id"], "volc.bigasr.sauc.duration")
        self.assertEqual(headers["X-Api-Connect-Id"], "connect-123")

    def test_full_client_request_payload_contains_user_audio_request_sections(self):
        payload = build_openspeech_full_client_request_payload(
            resource_id="volc.bigasr.sauc.duration",
            uid="speaker-1",
            reqid="req-1",
        )

        self.assertEqual(payload["user"]["uid"], "speaker-1")
        self.assertEqual(payload["audio"]["format"], "pcm")
        self.assertEqual(payload["audio"]["rate"], 16000)
        self.assertEqual(payload["audio"]["bits"], 16)
        self.assertEqual(payload["audio"]["channel"], 1)
        self.assertEqual(payload["audio"]["language"], "zh-CN")
        self.assertEqual(payload["request"]["reqid"], "req-1")
        self.assertEqual(payload["request"]["resource_id"], "volc.bigasr.sauc.duration")
        self.assertEqual(payload["request"]["model_name"], "bigmodel")
        self.assertEqual(payload["request"]["enable_itn"], False)
        self.assertEqual(payload["request"]["enable_ddc"], False)
        self.assertEqual(payload["request"]["enable_punc"], False)

    def test_provider_requires_appid_token_and_resource_id(self):
        with self.assertRaises(ValueError):
            VolcengineRealtimeProvider(appid="", access_token="token", resource_id="volc.bigasr.sauc.duration")
        with self.assertRaises(ValueError):
            VolcengineRealtimeProvider(appid="appid", access_token="", resource_id="volc.bigasr.sauc.duration")
        with self.assertRaises(ValueError):
            VolcengineRealtimeProvider(appid="appid", access_token="token", resource_id="")

    def test_parse_server_message_reads_gzip_json_full_response(self):
        payload = json.dumps(
            {
                "code": 1000,
                "message": "Success",
                "sequence": 2,
                "result": {"text": "你好世界"},
            }
        ).encode("utf-8")
        frame = (
            bytes([0x11, 0x91, 0x10, 0x00])
            + (2).to_bytes(4, "big", signed=True)
            + len(payload).to_bytes(4, "big")
            + payload
        )

        parsed = parse_server_message(frame)

        self.assertEqual(parsed["message_type"], 0x9)
        self.assertEqual(parsed["flags"], 0x1)
        self.assertEqual(parsed["sequence"], 2)
        self.assertEqual(parsed["payload"]["result"]["text"], "你好世界")

    def test_parse_server_message_reads_error_frame(self):
        payload = json.dumps({"error": "bad request"}).encode("utf-8")
        frame = (
            bytes([0x11, 0xF0, 0x10, 0x00])
            + (40000).to_bytes(4, "big")
            + len(payload).to_bytes(4, "big")
            + payload
        )

        parsed = parse_server_message(frame)

        self.assertEqual(parsed["message_type"], 0xF)
        self.assertEqual(parsed["error_code"], 40000)
        self.assertEqual(parsed["payload"]["error"], "bad request")

    def test_audio_only_request_frame_writes_payload_size_immediately_after_header(self):
        frame = build_audio_only_request_frame(b"\x01\x02", is_last=False)
        payload_size = int.from_bytes(frame[4:8], "big")

        self.assertEqual(frame[:4], b"\x11\x20\x01\x00")
        self.assertGreater(payload_size, 0)

    @patch.dict(
        os.environ,
        {
            "STT_WORKER_PROVIDER": "volcengine_realtime",
            "STT_WORKER_VOLCENGINE_APP_ID": "app-123",
            "STT_WORKER_VOLCENGINE_ACCESS_TOKEN": "token-123",
            "STT_WORKER_VOLCENGINE_RESOURCE_ID": "volc.bigasr.sauc.duration",
            "STT_WORKER_VOLCENGINE_WS_URL": "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel",
        },
        clear=False,
    )
    def test_load_config_reads_openspeech_settings(self):
        config = load_config()

        self.assertEqual(config.provider, "volcengine_realtime")
        self.assertEqual(config.volcengine_app_id, "app-123")
        self.assertEqual(config.volcengine_access_token, "token-123")
        self.assertEqual(config.volcengine_resource_id, "volc.bigasr.sauc.duration")
        self.assertEqual(config.volcengine_ws_url, "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")


class _FakeConnection:
    def __init__(self):
        self.sent_messages: list[bytes] = []
        self.closed = False
        self.recv_messages: list[bytes | str] = []

    async def send(self, payload):
        self.sent_messages.append(payload)

    async def recv(self):
        if not self.recv_messages:
            raise RuntimeError("recv not implemented in fake")
        return self.recv_messages.pop(0)

    async def close(self):
        self.closed = True


class VolcengineRealtimeProviderSessionTests(unittest.IsolatedAsyncioTestCase):
    @staticmethod
    def _build_server_frame(text: str, *, sequence: int, flags: int = 0x1) -> bytes:
        payload = json.dumps(
            {
                "code": 1000,
                "message": "Success",
                "sequence": sequence,
                "result": {"text": text},
            }
        ).encode("utf-8")
        return (
            bytes([0x11, (0x9 << 4) | flags, 0x10, 0x00])
            + int(sequence).to_bytes(4, "big", signed=True)
            + len(payload).to_bytes(4, "big")
            + payload
        )

    async def test_connect_uses_openspeech_url_and_token_header(self):
        captured = {}

        async def fake_connector(url, *, additional_headers):
            captured["url"] = url
            captured["headers"] = additional_headers
            return _FakeConnection()

        provider = VolcengineRealtimeProvider(
            appid="app-1",
            access_token="token-1",
            resource_id="volc.bigasr.sauc.duration",
        )
        provider._connector = fake_connector

        connection = await provider._connect()

        self.assertIsInstance(connection, _FakeConnection)
        self.assertEqual(captured["url"], OPENSPEECH_BIGMODEL_WS_URL)
        self.assertEqual(captured["headers"]["X-Api-App-Key"], "app-1")
        self.assertEqual(captured["headers"]["X-Api-Access-Key"], "token-1")
        self.assertEqual(captured["headers"]["X-Api-Resource-Id"], "volc.bigasr.sauc.duration")
        self.assertTrue(captured["headers"]["X-Api-Connect-Id"])

    async def test_start_session_sends_binary_full_client_request(self):
        provider = VolcengineRealtimeProvider(
            appid="app-1",
            access_token="token-1",
            resource_id="volc.bigasr.sauc.duration",
            speaker_identity="owner-1",
        )
        fake = _FakeConnection()
        provider._connection = fake

        started = await provider.start_session()

        self.assertEqual(started["type"], "session_started")
        self.assertEqual(started["provider"], "volcengine_realtime")
        self.assertEqual(len(fake.sent_messages), 1)
        self.assertIsInstance(fake.sent_messages[0], bytes)
        self.assertEqual(fake.sent_messages[0][:4], b"\x11\x10\x11\x00")

    async def test_push_chunk_sends_binary_audio_frame(self):
        provider = VolcengineRealtimeProvider(
            appid="app-1",
            access_token="token-1",
            resource_id="volc.bigasr.sauc.duration",
        )
        fake = _FakeConnection()
        fake.recv_messages.append(self._build_server_frame("", sequence=1))
        provider._connection = fake

        delta = await provider.push_chunk(b"\x01\x02", mime_type="audio/pcm;rate=16000")

        self.assertEqual(delta.message_type, "partial_transcript")
        self.assertEqual(delta.byte_count, 2)
        self.assertEqual(len(fake.sent_messages), 1)
        self.assertIsInstance(fake.sent_messages[0], bytes)
        self.assertEqual(fake.sent_messages[0][:4], b"\x11\x20\x01\x00")

    async def test_finalize_sends_last_audio_frame_flag_and_closes_connection(self):
        provider = VolcengineRealtimeProvider(
            appid="app-1",
            access_token="token-1",
            resource_id="volc.bigasr.sauc.duration",
        )
        fake = _FakeConnection()
        fake.recv_messages.append(self._build_server_frame("", sequence=-3, flags=0x3))
        provider._connection = fake
        provider._stats.chunk_count = 2
        provider._stats.byte_count = 6400

        delta = await provider.finalize()

        self.assertEqual(delta.message_type, "final_transcript")
        self.assertTrue(fake.closed)
        self.assertEqual(len(fake.sent_messages), 1)
        self.assertIsInstance(fake.sent_messages[0], bytes)
        self.assertEqual(delta.chunk_count, 2)
        self.assertEqual(fake.sent_messages[0][:4], b"\x11\x22\x01\x00")

    async def test_push_chunk_uses_server_partial_response_text(self):
        provider = VolcengineRealtimeProvider(
            appid="app-1",
            access_token="token-1",
            resource_id="volc.bigasr.sauc.duration",
        )
        fake = _FakeConnection()
        fake.recv_messages.append(self._build_server_frame("实时转写", sequence=2))
        provider._connection = fake

        delta = await provider.push_chunk(b"\x01\x02", mime_type="audio/pcm;rate=16000")

        self.assertEqual(delta.text, "实时转写")

    async def test_finalize_uses_server_final_response_text(self):
        provider = VolcengineRealtimeProvider(
            appid="app-1",
            access_token="token-1",
            resource_id="volc.bigasr.sauc.duration",
        )
        fake = _FakeConnection()
        fake.recv_messages.append(self._build_server_frame("最终文本", sequence=-3, flags=0x3))
        provider._connection = fake
        provider._stats.chunk_count = 2
        provider._stats.byte_count = 6400

        delta = await provider.finalize()

        self.assertEqual(delta.text, "最终文本")
