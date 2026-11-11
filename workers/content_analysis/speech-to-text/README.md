> Updated extraction flow: see `workers/content_analysis/EXTRACTION_ROLLOUT.md`
> from the repository root. Migration 013 unifies video and private Reading PDFs.
> Older video-only descriptions below document the compatibility baseline.

# SkillTrack local video transcription worker

This Windows worker downloads an authorized marketplace video from Supabase Storage, converts its audio with standalone FFmpeg, runs the standalone whisper.cpp `whisper-cli.exe`, and saves full text, detected language, and timestamped segments under the original resource ID. It does **not** call Buzz or the Python `openai-whisper` package. The temporary download, WAV, and JSON export are deleted after each job; the original Storage video is not deleted.

## Integration status

The project owner confirmed the existing `public.learning_resources` contract: UUID `id`, text `kind`, `status` and `external_url`, and non-null boolean `moderation_hidden`. Its base DDL and a resource-file table are absent from this checkout. Discovery uses the current Storage URL setup and does not create or alter marketplace tables.

Migration order is `001_video_transcription.sql`, `002_video_transcription_discovery.sql`, `003_consolidate_video_transcripts.sql`, then `004_simplify_video_transcripts.sql` in `../../../../supabase/migrations/`. Apply only the migrations not already installed. Stop all worker processes/discovery and take a backup before upgrading. Migration 003 copies every queue row and verifies the copy before removing the jobs table. Migration 004 removes job_id, queued_at, completed_at and max_attempts, replaces the legacy worker RPCs and returns video_transcripts.id as the sole work identifier. Start the updated worker only after 004 commits. Old worker processes must not run against the simplified schema.

The final table holds file identity, Storage location, nullable transcript_text, language, segments, status, attempt_count, claim_token, lease_expires_at, next_attempt_at, error_code, created_at and updated_at. Existing transcript UUIDs, content and created_at stay intact. Unfinished work remains as pending/processing/failed rows with NULL text. Active tokens, leases and retry counts survive; after a worker restart, an abandoned processing row is eligible again when its lease expires. Removed auxiliary timestamps and custom per-row retry limits are intentionally discarded. The server policy is now three attempts, including the first attempt. Existing failed rows stay failed, pending rows already at the limit become failed, and processing rows at the limit can finish before their lease expires.

The worker uses claim_video_transcript, renew_video_transcript, complete_video_transcript and fail_video_transcript. All state changes use the transcript primary key and atomic backend RPCs. Claiming uses FOR UPDATE SKIP LOCKED. Completion stores text and ready status in one update; ready rows require nonempty text. Enqueue and discovery return that same primary key and preserve source-version deduplication.

Both migrations use transactions and RESTRICT drops. Migration 003 checks that every work row was copied. Migration 004 checks remaining stored routine bodies for obsolete references and stops on dependent routines/views/foreign keys rather than silently removing callers. External scripts and dynamic SQL assembled outside this checkout require a deployment review. Historical migrations and their regression tests intentionally retain the previous schema references.

The server role needs existing SELECT and UPDATE privileges on learning_resources and storage.objects for SELECT FOR SHARE. The migrations retain RLS and backend-only RPC/table access. They do not grant clients permission to claim work or write transcript text. The local resource fixture follows the owner-confirmed UUID schema; no resource foreign key or type conversion is added to legacy opaque transcription IDs.

Normal discovery scans `kind = 'Video' AND status = 'published' AND moderation_hidden = false` in UUID order, one bounded page per cycle. Set `VIDEO_BUCKET` to the actual existing video bucket and optionally `DISCOVERY_BATCH_SIZE` (1�100, default 25). The worker accepts only stable HTTPS `/storage/v1/object/public/<bucket>/<path>` or `/storage/v1/object/authenticated/<bucket>/<path>` URLs on `SUPABASE_URL`. External, YouTube, signed, query-bearing and traversal URLs are skipped. Downloads use the authenticated Storage endpoint, never the resource URL itself.

The backend rechecks resource eligibility and object existence. The Storage object UUID becomes source_file_id, with Storage version, etag or updated_at as source_version. Replacing an object creates a new identity/version and permits another job. Matching transcripts and all existing jobs are skipped, including terminal failed jobs. Discovery never resets attempts. The existing atomic enqueue handles concurrent duplicate discovery.

The production uploader can still call `enqueue_video_transcription` after upload and resource creation commit. It must use the same Storage identity/version convention to deduplicate with automatic discovery. A future real file table needs an explicit adapter once its schema is available.

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

Edit `.env` with `SUPABASE_URL` and a **backend-only** `SUPABASE_SERVICE_ROLE_KEY`. Keep `.env` private. The example paths work with the local tools junction or a standalone installation in the same folder. Set `VIDEO_BUCKET` to the actual bucket. After reviewing and applying the four SQL files to your test project:

```powershell
# Discover one explicitly selected draft video, then process at most one queued job.
& '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker --once --draft-resource-id 'YOUR-DRAFT-RESOURCE-UUID'
# Continuously discover published videos and process the queue.
& '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker
```

The worker polls outward; the PC has no public endpoint. It claims one job with a token and renewable lease, handles bounded retries, and saves transcript and ready status in one database transaction. The PC must stay on for jobs to run. The successful path is `pending → processing → ready`.

The offline tests cover resource ID preservation, duplicate enqueue, stale claims, failures, temporary cleanup, JSON parsing, and command construction. A real PostgreSQL concurrent-claim test and live upload-to-transcript test still require a test database and the marketplace uploader. The PDF extractor, Flutter app, and recommendation logic are unchanged.

`--draft-resource-id` targets discovery only. Claiming still uses the existing global queue, so an older eligible job may be processed first. Other drafts are never scanned. `--once` discovers one page and processes at most one job. Continuous mode immediately checks again after `ready`, and waits POLL_SECONDS when idle or after failure. Pagination restarts after the final page or a worker restart; deduplication makes replay safe.

Offline verification uses `python -m unittest discover -s tests -v` here and `node --test supabase/tests/video_transcription_discovery.test.mjs supabase/tests/video_transcript_queue.test.mjs` from the repository root with PGLITE_MODULE pointing to an installed PGlite module if needed. SQL tests use a local fixture matching the owner-confirmed resource fields, not an exported production schema. Live verification still needs the actual bucket, resource rows, server-role grants, Storage version metadata and a real upload/replacement run. Queue-time object existence/version is checked; upload paths should be immutable during processing to avoid replacing bytes underneath an active job.

## Upload and analyser handoff

No uploader, Cloudinary integration or resource-file table is present in this checkout. The supported handoff is the verified Storage fallback: both a qualifying resource row and a matching committed storage.objects row must exist before enqueue. A resource insert alone never creates pending transcription work. If the real uploader uses Cloudinary, its asset identity/version, successful-upload callback and authenticated download contract still need integration; this worker only downloads from the configured Supabase Storage project/bucket.

The tag analyser's production ResourceStore remains unavailable because resource ownership, catalog and saved-analysis contracts are missing. There is currently no production transcript reader to rewire. Its future authorized adapter must use read_ready_video_transcript(resource UUID, saved external_url, verified bucket, decoded path). Validate the saved URL against the configured project/bucket and derive the path from that same URL. The RPC rechecks resource eligibility and compares the Storage object's current ID/version to a ready transcript. A replacement version returns no old text while new work is pending. Recheck the same version when saving analysis results. Historical ready rows remain stored for their original versions.

## Consolidation verification

Run the Python tests and demo above. From the repository root, run:

```powershell
node --test supabase/tests/video_transcription_discovery.test.mjs supabase/tests/video_transcript_queue.test.mjs
```

This uses locally installed @electric-sql/pglite (or PGLITE_MODULE pointing to its dist/index.js). It covers final-schema discovery, migration of existing completed/unfinished work, transcript-ID continuity, removed-column dependencies, retry limits, expired leases, stale completion, ready-text constraints, current-version reads and backend-only access. PGlite serializes requests on one connection; simultaneous calls test claim exclusivity but are not a multi-session PostgreSQL lock/load test. Verify that separately on a local/test PostgreSQL instance before deployment.

After migration, read-only SQL checks:

```sql
select to_regclass('public.video_transcription_jobs'); -- expected NULL
select status, count(*) from public.video_transcripts group by status;
select count(*) as invalid_ready_rows from public.video_transcripts
where status = 'ready' and (transcript_text is null or btrim(transcript_text) = '');
select relrowsecurity from pg_class where oid = 'public.video_transcripts'::regclass;
```

Verify actual deployed definitions/dependencies, service-role permissions, upload completion, stable Storage version metadata, replacement during processing and analyser ownership before enabling this on a live project. Prepared migrations have not been executed against live Supabase.
