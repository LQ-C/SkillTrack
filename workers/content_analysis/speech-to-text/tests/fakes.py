"""In-memory simulation of the SQL contract; no Supabase or model access."""

from __future__ import annotations

from pathlib import Path
import threading
import uuid
from typing import Any


class FakeGateway:
    def __init__(self, *, max_attempts: int = 3, video_bytes: bytes = b"simulated-video"):
        self.lock = threading.Lock()
        self.jobs: dict[str, dict[str, Any]] = {}
        self.keys: dict[tuple[str, str, str], str] = {}
        self.transcripts: dict[str, dict[str, Any]] = {}
        self.max_attempts = max_attempts
        self.video_bytes = video_bytes
        self.now = 1000.0
        self.downloaded_path: Path | None = None
        self.download_error = False
        self.history: list[str] = []

    def enqueue(self, resource_id: str, file_id: str, version: str,
                bucket: str = "marketplace-videos",
                path: str = "owner/resource/video.mp4") -> str:
        with self.lock:
            key = (resource_id, file_id, version)
            if key in self.keys:
                existing = self.jobs[self.keys[key]]
                if (existing["storage_bucket"], existing["storage_path"]) != (bucket, path):
                    raise ValueError("Version already enqueued for another object")
                return existing["job_id"]
            job_id = str(uuid.uuid4())
            self.keys[key] = job_id
            self.jobs[job_id] = {
                "job_id": job_id, "resource_id": resource_id,
                "source_file_id": file_id, "source_version": version,
                "storage_bucket": bucket, "storage_path": path,
                "status": "pending", "claim_token": None,
                "lease_until": None, "attempt_count": 0,
                "next_attempt_at": self.now,
            }
            self.history.append("pending")
            return job_id

    def advance(self, seconds: float) -> None:
        with self.lock:
            self.now += seconds

    def claim(self, lease_seconds: int) -> dict[str, Any] | None:
        with self.lock:
            for job in self.jobs.values():
                expired = job["status"] == "processing" and job["lease_until"] <= self.now
                if expired and job["attempt_count"] >= self.max_attempts:
                    job["status"] = "failed"
                    self.history.append("failed")
                    continue
                due = job["status"] == "pending" and job["next_attempt_at"] <= self.now
                if job["attempt_count"] < self.max_attempts and (due or expired):
                    job["status"] = "processing"
                    job["attempt_count"] += 1
                    job["claim_token"] = str(uuid.uuid4())
                    job["lease_until"] = self.now + lease_seconds
                    self.history.append("processing")
                    return dict(job)
            return None

    def renew(self, job_id: str, token: str, lease_seconds: int) -> bool:
        with self.lock:
            job = self.jobs[job_id]
            if not self._owns(job, token):
                return False
            job["lease_until"] = self.now + lease_seconds
            return True

    def _owns(self, job: dict[str, Any], token: str) -> bool:
        return (job["status"] == "processing" and job["claim_token"] == token
                and job["lease_until"] > self.now)

    def download(self, bucket: str, storage_path: str, destination: Path) -> None:
        self.downloaded_path = destination
        if self.download_error:
            destination.write_bytes(b"partial")
            raise OSError("simulated download failure")
        destination.write_bytes(self.video_bytes)

    def complete(self, job_id: str, token: str, transcript: str,
                 language: str | None, segments: list[dict[str, Any]]) -> bool:
        with self.lock:
            job = self.jobs[job_id]
            if job["status"] == "ready" and job["claim_token"] == token:
                return job_id in self.transcripts
            if not self._owns(job, token):
                return False
            self.transcripts[job_id] = {
                "resource_id": job["resource_id"],
                "source_file_id": job["source_file_id"],
                "source_version": job["source_version"],
                "transcript_text": transcript,
                "language": language,
                "segments": segments,
            }
            job["status"] = "ready"
            job["lease_until"] = None
            self.history.append("ready")
            return True

    def fail(self, job_id: str, token: str, error_code: str) -> bool:
        with self.lock:
            job = self.jobs[job_id]
            if not self._owns(job, token):
                return False
            job["status"] = "failed" if job["attempt_count"] >= self.max_attempts else "pending"
            job["error_code"] = error_code
            job["next_attempt_at"] = self.now + min(30, job["attempt_count"] * 2) * 60
            job["claim_token"] = None
            job["lease_until"] = None
            self.history.append(job["status"])
            return True


class FakeTranscriber:
    def __init__(self, *, fail: bool = False):
        self.fail = fail
        self.calls = 0

    def transcribe(self, video_path: Path):
        self.calls += 1
        assert video_path.read_bytes() == b"simulated-video"
        if self.fail:
            raise RuntimeError("simulated model failure")
        return (
            "Create Flutter folders for screens, models, and services.",
            "en",
            [{"start": 0.0, "end": 3.2,
              "text": "Create Flutter folders for screens, models, and services."}],
        )

