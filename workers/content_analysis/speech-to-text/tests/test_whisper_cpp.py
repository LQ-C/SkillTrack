from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from skilltrack_speech.transcriber import WhisperCppTranscriber, parse_whisper_json
from skilltrack_speech.worker import process_one
from tests.fakes import FakeGateway


RESULT = {
    "result": {"language": "ms"},
    "transcription": [
        {"offsets": {"from": 100, "to": 1500}, "text": "Selamat pagi."},
        {"offsets": {"from": 1500, "to": 3000}, "text": "Ini ujian."},
    ],
}


class WhisperCppTests(unittest.TestCase):
    def test_json_text_language_and_timestamps(self):
        text, language, segments = parse_whisper_json(json.dumps(RESULT))
        self.assertEqual(text, "Selamat pagi. Ini ujian.")
        self.assertEqual(language, "ms")
        self.assertEqual(segments[0], {"start": 0.1, "end": 1.5, "text": "Selamat pagi."})

    def test_forced_english_is_passed_to_cli(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli, ffmpeg, model = root / "whisper-cli.exe", root / "ffmpeg.exe", root / "ggml-small.bin"
            for file in (cli, ffmpeg, model):
                file.touch()
            video = root / "source.mp4"
            video.touch()

            def fake_run(command, **kwargs):
                if command[0] == str(ffmpeg):
                    Path(command[-1]).touch()
                else:
                    self.assertEqual(command[command.index("-l") + 1], "en")
                    Path(command[command.index("-of") + 1] + ".json").write_text(json.dumps(RESULT))
                return subprocess.CompletedProcess(command, 0)

            with patch("skilltrack_speech.transcriber.subprocess.run", side_effect=fake_run):
                WhisperCppTranscriber(str(cli), str(model), str(ffmpeg), language="en").transcribe(video)

    def test_direct_commands_and_worker_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli, ffmpeg, model = root / "whisper-cli.exe", root / "ffmpeg.exe", root / "ggml-small.bin"
            for file in (cli, ffmpeg, model):
                file.touch()
            gateway = FakeGateway()
            transcript_id = gateway.enqueue("SAMPLE-RESOURCE-001", "video-1", "v1")

            def fake_run(command, **kwargs):
                self.assertIs(kwargs["stdout"], subprocess.DEVNULL)
                if command[0] == str(ffmpeg):
                    self.assertIn("-ar", command)
                    self.assertIn("16000", command)
                    Path(command[-1]).write_bytes(b"wav")
                else:
                    self.assertEqual(command[0], str(cli))
                    self.assertIn("-l", command)
                    self.assertIn("en", command)
                    self.assertIn("-oj", command)
                    self.assertNotIn("-ng", command)
                    self.assertIn(str(model), command)
                    output = Path(command[command.index("-of") + 1] + ".json")
                    output.write_text(json.dumps(RESULT), encoding="utf-8")
                return subprocess.CompletedProcess(command, 0)

            transcriber = WhisperCppTranscriber(str(cli), str(model), str(ffmpeg))
            with patch("skilltrack_speech.transcriber.subprocess.run", side_effect=fake_run):
                self.assertEqual(process_one(gateway, transcriber), "ready")
            saved = gateway.transcripts[transcript_id]
            self.assertEqual(saved["resource_id"], "SAMPLE-RESOURCE-001")
            self.assertEqual(saved["language"], "ms")
            self.assertEqual(len(saved["segments"]), 2)
            self.assertFalse(gateway.downloaded_path.exists())
            self.assertFalse(gateway.downloaded_path.parent.joinpath("audio-16khz.wav").exists())

    def test_failed_conversion_records_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli, ffmpeg, model = root / "whisper-cli.exe", root / "ffmpeg.exe", root / "ggml-small.bin"
            for file in (cli, ffmpeg, model):
                file.touch()
            gateway = FakeGateway()
            gateway.enqueue("r1", "f1", "v1")
            transcriber = WhisperCppTranscriber(str(cli), str(model), str(ffmpeg))
            with patch("skilltrack_speech.transcriber.subprocess.run",
                       return_value=subprocess.CompletedProcess([], 1)):
                self.assertEqual(process_one(gateway, transcriber), "transcription_failed")
            self.assertEqual(len(gateway.transcripts), 1)
            row = next(iter(gateway.transcripts.values()))
            self.assertIsNone(row["transcript_text"])
            self.assertEqual(row["status"], "pending")
            self.assertFalse(gateway.downloaded_path.exists())

    def test_cpu_mode_adds_no_gpu_flag(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cli, ffmpeg, model = root / "whisper-cli.exe", root / "ffmpeg.exe", root / "ggml-small.bin"
            for file in (cli, ffmpeg, model):
                file.touch()
            video = root / "source.mp4"
            video.touch()

            def fake_run(command, **kwargs):
                if command[0] == str(ffmpeg):
                    Path(command[-1]).touch()
                else:
                    self.assertIn("-ng", command)
                    Path(command[command.index("-of") + 1] + ".json").write_text(json.dumps(RESULT))
                return subprocess.CompletedProcess(command, 0)

            with patch("skilltrack_speech.transcriber.subprocess.run", side_effect=fake_run):
                WhisperCppTranscriber(str(cli), str(model), str(ffmpeg), use_gpu=False).transcribe(video)


if __name__ == "__main__":
    unittest.main()
