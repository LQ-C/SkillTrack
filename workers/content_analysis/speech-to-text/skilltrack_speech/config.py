"""Configuration read from the worker's process environment."""

from __future__ import annotations

from dataclasses import dataclass
import os


@dataclass(frozen=True)
class Config:
    supabase_url: str
    service_role_key: str
    whisper_cpp_exe: str = "tools/whisper-cuda/Release/whisper-cli.exe"
    model_file: str = "tools/ggml-small.bin"
    ffmpeg_exe: str = "tools/ffmpeg.exe"
    transcribe_timeout_seconds: int = 7200
    whisper_cpp_language: str = "en"
    whisper_cpp_use_gpu: bool = True
    poll_seconds: int = 30
    lease_seconds: int = 900
    renew_seconds: int = 60
    max_video_mb: int = 1024
    video_bucket: str = ""
    pdf_bucket: str = "marketplace-documents"
    discovery_batch_size: int = 25

    @classmethod
    def from_env(cls) -> "Config":
        url = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
        key = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip()
        if not url.startswith("https://") or not key:
            raise ValueError("Set SUPABASE_URL (HTTPS) and SUPABASE_SERVICE_ROLE_KEY")
        config = cls(
            supabase_url=url,
            service_role_key=key,
            whisper_cpp_exe=os.getenv("WHISPER_CPP_EXE", "tools/whisper-cuda/Release/whisper-cli.exe").strip(),
            model_file=os.getenv("WHISPER_CPP_MODEL", "tools/ggml-small.bin").strip(),
            ffmpeg_exe=os.getenv("FFMPEG_EXE", "tools/ffmpeg.exe").strip(),
            transcribe_timeout_seconds=int(os.getenv("TRANSCRIBE_TIMEOUT_SECONDS", "7200")),
            whisper_cpp_language=os.getenv("WHISPER_CPP_LANGUAGE", "en").strip().lower(),
            whisper_cpp_use_gpu=os.getenv("WHISPER_CPP_USE_GPU", "true").strip().lower() in {"true", "1", "yes"},
            poll_seconds=int(os.getenv("POLL_SECONDS", "30")),
            lease_seconds=int(os.getenv("LEASE_SECONDS", "900")),
            renew_seconds=int(os.getenv("RENEW_SECONDS", "60")),
            max_video_mb=int(os.getenv("MAX_VIDEO_MB", "1024")),
            video_bucket=os.getenv("VIDEO_BUCKET", "").strip(),
            pdf_bucket=os.getenv("PDF_BUCKET", "marketplace-documents").strip(),
            discovery_batch_size=int(os.getenv("DISCOVERY_BATCH_SIZE", "25")),
        )
        if (not config.whisper_cpp_exe or not config.model_file or not config.ffmpeg_exe
                or config.transcribe_timeout_seconds < 1 or config.poll_seconds < 1
                or config.lease_seconds < 30):
            raise ValueError("Invalid whisper.cpp or worker settings")
        if not 1 <= config.renew_seconds < config.lease_seconds or config.max_video_mb < 1:
            raise ValueError("Renew interval must be shorter than lease; max video size must be positive")
        if not config.video_bucket or "/" in config.video_bucket:
            raise ValueError("Set VIDEO_BUCKET to the existing video bucket")
        if config.pdf_bucket != "marketplace-documents":
            raise ValueError("PDF_BUCKET must match the verified marketplace-documents contract")
        if not 1 <= config.discovery_batch_size <= 100:
            raise ValueError("DISCOVERY_BATCH_SIZE must be between 1 and 100")
        return config

