"""Test direct local video transcription without Supabase."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import tempfile

from skilltrack_speech.transcriber import WhisperCppTranscriber


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path, help="Local video file to transcribe")
    parser.add_argument("--language", default="en", help="Language code, e.g. en or auto; default: en")
    parser.add_argument("--cpu", action="store_true", help="Disable GPU acceleration")
    args = parser.parse_args()
    if not args.video.is_file():
        parser.error("Video file was not found")
    root = Path(__file__).resolve().parent
    transcriber = WhisperCppTranscriber(
        str(root / "tools/whisper-cuda/Release/whisper-cli.exe"),
        str(root / "tools/ggml-small.bin"),
        str(root / "tools/ffmpeg.exe"),
        language=args.language,
        use_gpu=not args.cpu,
    )
    with tempfile.TemporaryDirectory(prefix="skilltrack-local-test-") as temp:
        sample = Path(temp) / ("source" + args.video.suffix.lower())
        shutil.copyfile(args.video, sample)
        text, language, segments = transcriber.transcribe(sample)
        print(f"Detected language: {language or 'unknown'}")
        print(f"Segments: {len(segments)}")
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
