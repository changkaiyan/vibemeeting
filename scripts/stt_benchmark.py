#!/usr/bin/env python3
import argparse
import asyncio
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from services.stt_worker.stt_worker.benchmark import BenchmarkConfig
from services.stt_worker.stt_worker.benchmark import run_benchmark


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run CLI benchmark against the realtime STT websocket endpoint.")
    parser.add_argument("--url", required=True, help="WebSocket URL, either the worker endpoint or Django STT endpoint.")
    parser.add_argument("--iterations", type=int, default=1, help="Number of benchmark sessions to run.")
    parser.add_argument("--concurrency", type=int, default=1, help="Number of sessions to run in parallel.")
    parser.add_argument("--chunk-ms", type=int, default=200, help="PCM chunk size in milliseconds.")
    parser.add_argument("--speech-duration-ms", type=int, default=1200, help="Synthetic speech duration per session in milliseconds.")
    parser.add_argument("--trailing-silence-ms", type=int, default=600, help="Synthetic silence appended after speech.")
    parser.add_argument("--sample-rate", type=int, default=16000, help="PCM sample rate.")
    parser.add_argument("--amplitude", type=int, default=1200, help="PCM amplitude used for synthetic speech.")
    parser.add_argument("--send-interval-ms", type=int, default=0, help="Optional sleep after each chunk send.")
    return parser


async def _main() -> int:
    args = build_parser().parse_args()
    report = await run_benchmark(
        BenchmarkConfig(
            url=args.url,
            iterations=args.iterations,
            concurrency=args.concurrency,
            chunk_ms=args.chunk_ms,
            speech_duration_ms=args.speech_duration_ms,
            trailing_silence_ms=args.trailing_silence_ms,
            sample_rate=args.sample_rate,
            amplitude=args.amplitude,
            send_interval_ms=args.send_interval_ms,
        )
    )
    print(
        json.dumps(
            {
                "config": report.config.__dict__,
                "summary": report.summary.__dict__,
                "sessions": [session.__dict__ for session in report.sessions],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0 if report.summary.successful_sessions == report.summary.total_sessions else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
