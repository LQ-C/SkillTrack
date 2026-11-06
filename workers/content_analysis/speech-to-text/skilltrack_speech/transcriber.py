"""Transcribe a temporary video with standalone FFmpeg and whisper.cpp tools."""

from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any


def _program(value: str, label: str) -> str:
    """Resolve an executable path or a command available on PATH."""
    found = shutil.which(value)
    if found is None or not Path(found).is_file():
        raise FileNotFoundError(f"{label} executable was not found")
    return found


def parse_whisper_json(contents: str) -> tuple[str, str | None, list[dict[str, Any]]]:
    """Read the language, full text, and timestamped segments from CLI JSON."""
    data = json.loads(contents)
    language = data.get("result", {}).get("language")
    segments: list[dict[str, Any]] = []
    for item in data.get("transcription", []):
        timing = item.get("offsets", {})
        words = str(item.get("text") or "").strip()
        start = float(timing["from"]) / 1000
        end = float(timing["to"]) / 1000
        if words and 0 <= start <= end:
            segments.append({"start": start, "end": end, "text": words})
    if not segments:
        raise RuntimeError("whisper.cpp produced no timestamped speech")
    text = " ".join(item["text"] for item in segments)
    return text, str(language) if language else None, segments


class WhisperCppTranscriber:
    def __init__(self, cli_exe: str, model_file: str, ffmpeg_exe: str = "ffmpeg",
                 timeout_seconds: int = 7200, language: str = "en", use_gpu: bool = True):
        self.cli_exe = _program(cli_exe, "whisper.cpp")
        self.ffmpeg_exe = _program(ffmpeg_exe, "FFmpeg")
        self.model_file = Path(model_file).resolve()
        if not self.model_file.is_file():
            raise FileNotFoundError("whisper.cpp model file was not found")
        if timeout_seconds < 1:
            raise ValueError("Timeout must be positive")
        if language != "auto" and not re.fullmatch(r"[a-z]{2,3}", language):
            raise ValueError("Language must be 'auto' or a language code such as 'en'")
        self.timeout_seconds = timeout_seconds
        self.language = language
        self.use_gpu = use_gpu

    def transcribe(self, video_path: Path) -> tuple[str, str | None, list[dict[str, Any]]]:
        # The worker owns this temporary directory. The original Storage object
        # is never modified or deleted.
        audio = video_path.parent / "audio-16khz.wav"
        output_base = video_path.parent / "transcript"
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        convert = [
            self.ffmpeg_exe, "-nostdin", "-hide_banner", "-loglevel", "error",
            "-y", "-i", str(video_path), "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le", str(audio),
        ]
        result = subprocess.run(
            convert, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=self.timeout_seconds, creationflags=flags, check=False,
        )
        if result.returncode != 0 or not audio.is_file():
            raise RuntimeError("Video audio conversion failed")

        command = [
            self.cli_exe, "-m", str(self.model_file), "-f", str(audio),
            "-l", self.language, "-oj", "-of", str(output_base),
        ]
        if not self.use_gpu:
            command.append("-ng")
        result = subprocess.run(
            command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=self.timeout_seconds, creationflags=flags, check=False,
        )
        exported = output_base.with_suffix(".json")
        if result.returncode != 0 or not exported.is_file():
            raise RuntimeError("whisper.cpp transcription failed")
        return parse_whisper_json(exported.read_text(encoding="utf-8-sig"))
