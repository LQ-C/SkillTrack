# SkillTrack local video transcription worker

This Windows worker downloads an authorized marketplace video from Supabase Storage, converts its audio with standalone FFmpeg, runs the standalone whisper.cpp `whisper-cli.exe`, and saves full text, detected language, and timestamped segments under the original resource ID. It does **not** call Buzz or the Python `openai-whisper` package. The temporary download, WAV, and JSON export are deleted after each job; the original Storage video is not deleted.

## Integration status

The available SkillTrack code has no marketplace resource table, resource-file table, uploader, or successful upload callback. The SQL in `../../../supabase/migrations/001_video_transcription.sql` is **local and unapplied**. It uses opaque text resource/file IDs until the real schema is available; there is no invented marketplace foreign key.

After **both** the Storage upload and resource/file save succeed, the trusted backend must verify ownership and call `enqueue_video_transcription` with the original resource ID, unique video file ID, immutable source version, bucket, and object path. Do not call this service-role RPC from Flutter. Retries with the same identifiers are safe. The teammate must check the real ID types, resource/file relationship, bucket/path, and upload callback, then add the real ownership check or foreign key before applying the migration.

Example RPC arguments (**sample IDs only**):

```json
{
  "p_resource_id": "SAMPLE-RESOURCE-001",
  "p_source_file_id": "SAMPLE-VIDEO-FILE-001",
  "p_source_version": "sample-version-1",
  "p_storage_bucket": "marketplace-videos",
  "p_storage_path": "owner/resource/upload-version-1.mp4"
}
```

## Standalone tools on Windows

This PC uses the multilingual `ggml-small.bin` model with an NVIDIA CUDA build of Whisper.cpp. The RTX 5060 Ti has 16 GB of VRAM, and a local test confirmed the CLI loaded the model on the GPU. The worker exports JSON with language and timestamps. Its default language is English because automatic detection incorrectly chose Malay for the short English sample; set `WHISPER_CPP_LANGUAGE=auto` for mixed-language uploads or another code such as `ms` for Malay. The `.en` models cannot transcribe other languages. [Whisper.cpp CLI options](https://github.com/ggml-org/whisper.cpp/blob/master/examples/cli/README.md). The CLI accepts 16-bit WAV audio, so FFmpeg converts the temporary video first. [Whisper.cpp audio instructions](https://github.com/ggml-org/whisper.cpp/blob/master/README.md).

This folder expects:

```text
tools/whisper-cuda/Release/whisper-cli.exe
tools/whisper-cuda/Release/*.dll
tools/ggml-small.bin
tools/ffmpeg.exe
```

`whisper-cli.exe` and its DLLs came from the [official Windows CUDA 12.4 x64 release](https://github.com/ggml-org/whisper.cpp/releases). The model came from [Whisper.cpp's model repository](https://huggingface.co/ggerganov/whisper.cpp/tree/main). On this PC, `tools/ffmpeg.exe` is a local copy of the FFmpeg executable previously bundled with Buzz; the worker never calls Buzz and will still run if Buzz is uninstalled. For another PC, get a standalone FFmpeg build from [Gyan](https://www.gyan.dev/ffmpeg/builds/). These binaries and model are ignored by Git; do not commit or redistribute them as part of the source code.

If the `tools` folder is absent on another PC, run these PowerShell commands from the relocated `speech-to-text` directory:

```powershell
New-Item -ItemType Directory -Force tools | Out-Null
Invoke-WebRequest 'https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-bin-win-cuda-12.4.0-x64.zip' -OutFile tools/whisper-cuda.zip
Expand-Archive tools/whisper-cuda.zip -DestinationPath tools/whisper-cuda -Force
Invoke-WebRequest 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin?download=true' -OutFile tools/ggml-small.bin
```

Download the **release essentials ZIP** from the FFmpeg link above, extract it, and copy its `bin/ffmpeg.exe` into `tools/ffmpeg.exe`. Verify all three before starting:

```powershell
& './tools/whisper-cuda/Release/whisper-cli.exe' --help
& './tools/ffmpeg.exe' -version
(Get-FileHash './tools/ggml-small.bin' -Algorithm SHA1).Hash
```

The small model's published SHA1 is `55356645C2B361A969DFD0EF2C5A50D530AFD8D5`. [Official model list](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md). The GPU build needs a compatible NVIDIA GPU and driver; this exact combination was tested on this PC. Set `WHISPER_CPP_USE_GPU=false` to append Whisper.cpp's `-ng` CPU option.

## Python environment

From PowerShell, create a fresh environment in the relocated Content Analysis directory:

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack\workers\content_analysis'
py -3.13 -m venv .venv
& '.\.venv\Scripts\python.exe' -m pip install -r '.\speech-to-text\requirements.txt' PyMuPDF
```

PyMuPDF is used by the PDF extractor. The original virtual environment stays in its original folder.

## Reuse the existing tools on this PC

The Git-ignored junctions below keep the model, binaries and English OCR data at their original locations. Run these commands from the Content Analysis directory if the junctions are missing.

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack\workers\content_analysis'
$sourceTools = 'C:\Users\PC\Documents\FYP\Content_Analysis_model'
if (-not (Test-Path -LiteralPath '.\speech-to-text\tools')) {
    New-Item -ItemType Junction -Path '.\speech-to-text\tools' -Target (Join-Path $sourceTools 'speech-to-text\tools')
}
if (-not (Test-Path -LiteralPath '.\Tesseract-OCR')) {
    New-Item -ItemType Junction -Path '.\Tesseract-OCR' -Target (Join-Path $sourceTools 'Tesseract-OCR')
}
```

On another PC, install the standalone tools described above and put English Tesseract data at `Tesseract-OCR/tessdata/eng.traineddata` under the Content Analysis directory.

## PDF extraction

From the Content Analysis directory, run the existing PDF extractor against a local file. Keep input PDFs and output text outside the repository or in its ignored local folders.

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack\workers\content_analysis'
& '.\.venv\Scripts\python.exe' '.\pdf_extraction.py' 'C:\path\to\sample.pdf'
```

## Local test without Supabase

From PowerShell:

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack\workers\content_analysis\speech-to-text'
& '..\.venv\Scripts\python.exe' -m unittest discover -s tests -v
& '..\.venv\Scripts\python.exe' demo_simulated.py
& '..\.venv\Scripts\python.exe' test_local.py 'C:\path\to\sample.mp4'
```

The first two commands use fakes and do not access Supabase. `test_local.py` runs FFmpeg and Whisper.cpp on your actual video, printing language and transcript. It does not upload or save anything to Supabase. All test files are temporary.

The tiny model guessed Malay for this short English sample. The small model also guessed Malay when set to automatic detection, so the test and worker now use English by default. Pass `--language auto` to test automatic detection; the result may be incorrect on short speech.

## Start the Supabase worker

From the relocated speech-to-text directory, create a private configuration from the template if needed.

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack\workers\content_analysis\speech-to-text'
if (-not (Test-Path -LiteralPath '.env')) {
    Copy-Item -LiteralPath '.env.example' -Destination '.env'
}
```

Edit `.env` with `SUPABASE_URL` and a **backend-only** `SUPABASE_SERVICE_ROLE_KEY`. Keep `.env` private. The example paths work with the local tools junction or a standalone installation in the same folder. After reviewing and applying the SQL to a **test** Supabase project and adding the trusted uploader enqueue call:

```powershell
& '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker --once
& '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker
```

The worker polls outward; the PC has no public endpoint. It claims one job with a token and renewable lease, handles bounded retries, and saves transcript and ready status in one database transaction. The PC must stay on for jobs to run. The successful path is `pending → processing → ready`.

The offline tests cover resource ID preservation, duplicate enqueue, stale claims, failures, temporary cleanup, JSON parsing, and command construction. A real PostgreSQL concurrent-claim test and live upload-to-transcript test still require a test database and the marketplace uploader. The PDF extractor, Flutter app, and recommendation logic are unchanged.
