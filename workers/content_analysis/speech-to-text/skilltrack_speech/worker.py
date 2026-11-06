"""Poll Supabase for one video transcription at a time."""

from __future__ import annotations

import argparse
from pathlib import Path
import tempfile
import threading
import time
from typing import Any, Protocol

from .config import Config
from .supabase_gateway import SupabaseGateway
from .transcriber import WhisperCppTranscriber


class Gateway(Protocol):
    def claim(self, lease_seconds: int) -> dict[str, Any] | None: ...
    def renew(self, job_id: str, token: str, lease_seconds: int) -> bool: ...
    def download(self, bucket: str, storage_path: str, destination: Path) -> None: ...
    def complete(self, job_id: str, token: str, transcript: str,
                 language: str | None, segments: list[dict[str, Any]]) -> bool: ...
    def fail(self, job_id: str, token: str, error_code: str) -> bool: ...


class Transcriber(Protocol):
    def transcribe(self, video_path: Path) -> tuple[str, str | None, list[dict[str, Any]]]: ...


def _required(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"Claim response has no {key}")
    return value


def process_one(gateway: Gateway, transcriber: Transcriber, *,
                lease_seconds: int = 900, renew_seconds: int = 60) -> str | None:
    """Return None when idle; otherwise process a claimed job once."""
    payload = gateway.claim(lease_seconds)
    if payload is None:
        return None
    job_id = _required(payload, "job_id")
    token = _required(payload, "claim_token")
    bucket = _required(payload, "storage_bucket")
    storage_path = _required(payload, "storage_path")
    _required(payload, "resource_id")
    _required(payload, "source_file_id")
    _required(payload, "source_version")

    stop = threading.Event()
    lost_claim = threading.Event()

    def keep_lease() -> None:
        while not stop.wait(renew_seconds):
            try:
                if not gateway.renew(job_id, token, lease_seconds):
                    lost_claim.set()
                    return
            except Exception:
                lost_claim.set()
                return

    heartbeat = threading.Thread(target=keep_lease, daemon=True)
    heartbeat.start()
    phase = "download_failed"
    try:
        with tempfile.TemporaryDirectory(prefix="skilltrack-transcribe-") as temp:
            suffix = Path(storage_path).suffix.lower()
            if suffix not in {".mp4", ".mov", ".mkv", ".webm", ".m4v", ".avi"}:
                suffix = ".video"
            video = Path(temp) / f"source{suffix}"
            gateway.download(bucket, storage_path, video)
            if lost_claim.is_set():
                return "lease_lost"
            phase = "transcription_failed"
            text, language, segments = transcriber.transcribe(video)
            if lost_claim.is_set():
                return "lease_lost"
            phase = "save_failed"
            if not gateway.complete(job_id, token, text, language, segments):
                return "lease_lost"
            return "ready"
    except Exception:
        # Do not persist or print raw exception text: it may contain a signed URL or path.
        if lost_claim.is_set():
            return "lease_lost"
        gateway.fail(job_id, token, phase)
        return phase
    finally:
        stop.set()
        heartbeat.join(timeout=5)


def run_forever(config: Config) -> None:
    gateway = SupabaseGateway(config)
    transcriber = WhisperCppTranscriber(config.whisper_cpp_exe, config.model_file,
                                       config.ffmpeg_exe, config.transcribe_timeout_seconds,
                                       config.whisper_cpp_language, config.whisper_cpp_use_gpu)
    print("Worker running with local whisper.cpp; Ctrl+C to stop")
    while True:
        try:
            outcome = process_one(
                gateway, transcriber,
                lease_seconds=config.lease_seconds,
                renew_seconds=config.renew_seconds,
            )
            if outcome is not None:
                print(f"Transcription job outcome: {outcome}")
        except KeyboardInterrupt:
            raise
        except Exception:
            # A claimed job remains recoverable after its lease expires.
            print("Worker request failed; retrying after poll interval")
        time.sleep(config.poll_seconds)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="Check for one job then exit")
    args = parser.parse_args()
    try:
        from dotenv import load_dotenv
    except ImportError as exc:
        raise SystemExit("Install requirements.txt first") from exc
    load_dotenv()
    config = Config.from_env()
    try:
        if args.once:
            outcome = process_one(
                SupabaseGateway(config),
                WhisperCppTranscriber(config.whisper_cpp_exe, config.model_file,
                                      config.ffmpeg_exe, config.transcribe_timeout_seconds,
                                      config.whisper_cpp_language, config.whisper_cpp_use_gpu),
                lease_seconds=config.lease_seconds, renew_seconds=config.renew_seconds,
            )
            print(outcome or "no pending jobs")
        else:
            run_forever(config)
    except KeyboardInterrupt:
        print("Worker stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

