import asyncio
import base64
import json
from collections import Counter
from dataclasses import dataclass
from time import perf_counter

from services.stt_worker.stt_worker.schemas import AudioChunk


@dataclass(frozen=True)
class BenchmarkConfig:
    url: str
    concurrency: int = 1
    iterations: int = 1
    chunk_ms: int = 200
    speech_duration_ms: int = 1200
    trailing_silence_ms: int = 600
    sample_rate: int = 16000
    amplitude: int = 1200
    send_interval_ms: int = 0
    connect_timeout_sec: float = 5.0

    def __post_init__(self):
        if not (self.url or "").strip():
            raise ValueError("url is required")
        if self.concurrency <= 0:
            raise ValueError("concurrency must be positive")
        if self.iterations <= 0:
            raise ValueError("iterations must be positive")
        if self.chunk_ms <= 0:
            raise ValueError("chunk_ms must be positive")
        if self.speech_duration_ms <= 0:
            raise ValueError("speech_duration_ms must be positive")
        if self.trailing_silence_ms < 0:
            raise ValueError("trailing_silence_ms must be non-negative")
        if self.sample_rate <= 0:
            raise ValueError("sample_rate must be positive")
        if self.send_interval_ms < 0:
            raise ValueError("send_interval_ms must be non-negative")


@dataclass(frozen=True)
class BenchmarkSessionResult:
    ok: bool
    sent_chunks: int
    sent_bytes: int
    first_partial_latency_ms: float | None
    final_latency_ms: float | None
    wall_time_ms: float
    error: str


@dataclass(frozen=True)
class BenchmarkSummary:
    total_sessions: int
    successful_sessions: int
    success_rate: float
    first_partial_p50_ms: float | None
    first_partial_p95_ms: float | None
    final_p50_ms: float | None
    final_p95_ms: float | None
    bytes_per_second: float
    error_counts: dict[str, int]


@dataclass(frozen=True)
class BenchmarkReport:
    config: BenchmarkConfig
    sessions: list[BenchmarkSessionResult]
    summary: BenchmarkSummary


def _build_pcm16_frame(*, sample_count: int, amplitude: int) -> bytes:
    if amplitude == 0:
        return b"\x00\x00" * sample_count
    sample = int(amplitude).to_bytes(2, "little", signed=True)
    return sample * sample_count


def build_pcm16_chunk_plan(
    *,
    sample_rate: int,
    chunk_ms: int,
    speech_duration_ms: int,
    trailing_silence_ms: int,
    amplitude: int = 1200,
) -> list[AudioChunk]:
    if chunk_ms <= 0:
        raise ValueError("chunk_ms must be positive")
    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")

    samples_per_chunk = max(1, sample_rate * chunk_ms // 1000)
    total_speech_chunks = max(1, (speech_duration_ms + chunk_ms - 1) // chunk_ms)
    total_silence_chunks = max(0, (trailing_silence_ms + chunk_ms - 1) // chunk_ms)

    chunks: list[AudioChunk] = []
    mime_type = f"audio/pcm;rate={sample_rate};channels=1"
    for _ in range(total_speech_chunks):
        chunks.append(AudioChunk(payload=_build_pcm16_frame(sample_count=samples_per_chunk, amplitude=amplitude), mime_type=mime_type))
    for _ in range(total_silence_chunks):
        chunks.append(AudioChunk(payload=_build_pcm16_frame(sample_count=samples_per_chunk, amplitude=0), mime_type=mime_type))
    return chunks


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    ordered = sorted(values)
    offset = (len(ordered) - 1) * percentile
    lower = int(offset)
    upper = min(lower + 1, len(ordered) - 1)
    weight = offset - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * weight


def summarize_results(results: list[BenchmarkSessionResult]) -> BenchmarkSummary:
    total_sessions = len(results)
    successful = [result for result in results if result.ok]
    partials = [value for value in (result.first_partial_latency_ms for result in successful) if value is not None]
    finals = [value for value in (result.final_latency_ms for result in successful) if value is not None]
    error_counts = dict(Counter(result.error for result in results if result.error))
    total_wall_seconds = sum(result.wall_time_ms for result in successful) / 1000.0
    total_bytes = sum(result.sent_bytes for result in successful)
    return BenchmarkSummary(
        total_sessions=total_sessions,
        successful_sessions=len(successful),
        success_rate=(len(successful) / total_sessions) if total_sessions else 0.0,
        first_partial_p50_ms=_percentile(partials, 0.5),
        first_partial_p95_ms=_percentile(partials, 0.95),
        final_p50_ms=_percentile(finals, 0.5),
        final_p95_ms=_percentile(finals, 0.95),
        bytes_per_second=(total_bytes / total_wall_seconds) if total_wall_seconds > 0 else 0.0,
        error_counts=error_counts,
    )


async def _receive_json(websocket) -> dict:
    raw_message = await websocket.recv()
    if isinstance(raw_message, bytes):
        raw_message = raw_message.decode("utf-8")
    return json.loads(raw_message)


async def _run_single_session(config: BenchmarkConfig, index: int) -> BenchmarkSessionResult:
    from websockets.asyncio.client import connect

    chunk_plan = build_pcm16_chunk_plan(
        sample_rate=config.sample_rate,
        chunk_ms=config.chunk_ms,
        speech_duration_ms=config.speech_duration_ms,
        trailing_silence_ms=config.trailing_silence_ms,
        amplitude=config.amplitude,
    )
    wall_started = perf_counter()
    sent_bytes = 0
    sent_chunks = 0
    first_partial_latency_ms = None
    final_latency_ms = None
    try:
        async with connect(config.url, open_timeout=config.connect_timeout_sec) as websocket:
            await websocket.send(
                json.dumps(
                    {
                        "type": "start",
                        "speaker_name": f"benchmark-{index}",
                        "speaker_identity": f"bench-{index}",
                    }
                )
            )
            started_payload = await _receive_json(websocket)
            if (started_payload.get("type") or "").strip().lower() != "session_started":
                raise RuntimeError(f"unexpected start response: {started_payload}")
            session_started = perf_counter()
            for chunk in chunk_plan:
                await websocket.send(
                    json.dumps(
                        {
                            "type": "audio_chunk",
                            "mime_type": chunk.mime_type,
                            "data_base64": base64.b64encode(chunk.payload).decode("ascii"),
                        }
                    )
                )
                sent_chunks += 1
                sent_bytes += len(chunk.payload)
                response = await _receive_json(websocket)
                message_type = (response.get("type") or "").strip().lower()
                now = perf_counter()
                if message_type == "partial_transcript" and first_partial_latency_ms is None:
                    first_partial_latency_ms = (now - session_started) * 1000.0
                if message_type == "final_transcript":
                    final_latency_ms = (now - session_started) * 1000.0
                    break
                if message_type == "error":
                    raise RuntimeError(response.get("detail") or "worker returned error")
                if config.send_interval_ms > 0:
                    await asyncio.sleep(config.send_interval_ms / 1000.0)
            if final_latency_ms is None:
                await websocket.send(json.dumps({"type": "stop"}))
                response = await _receive_json(websocket)
                message_type = (response.get("type") or "").strip().lower()
                if message_type == "error":
                    raise RuntimeError(response.get("detail") or "worker returned error")
                if message_type != "final_transcript":
                    raise RuntimeError(f"unexpected stop response: {response}")
                final_latency_ms = (perf_counter() - session_started) * 1000.0
        return BenchmarkSessionResult(
            ok=True,
            sent_chunks=sent_chunks,
            sent_bytes=sent_bytes,
            first_partial_latency_ms=first_partial_latency_ms,
            final_latency_ms=final_latency_ms,
            wall_time_ms=(perf_counter() - wall_started) * 1000.0,
            error="",
        )
    except Exception as exc:
        return BenchmarkSessionResult(
            ok=False,
            sent_chunks=sent_chunks,
            sent_bytes=sent_bytes,
            first_partial_latency_ms=first_partial_latency_ms,
            final_latency_ms=final_latency_ms,
            wall_time_ms=(perf_counter() - wall_started) * 1000.0,
            error=str(exc),
        )


async def run_benchmark(config: BenchmarkConfig) -> BenchmarkReport:
    semaphore = asyncio.Semaphore(config.concurrency)

    async def runner(index: int) -> BenchmarkSessionResult:
        async with semaphore:
            return await _run_single_session(config, index)

    sessions = await asyncio.gather(*(runner(index) for index in range(config.iterations)))
    return BenchmarkReport(
        config=config,
        sessions=sessions,
        summary=summarize_results(sessions),
    )
