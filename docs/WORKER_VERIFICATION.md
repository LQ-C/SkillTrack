> Current split-bucket update: [RESOURCE_BUCKET_SPLIT.md](RESOURCE_BUCKET_SPLIT.md). New MP4 uploads now use mentor-video-files; legacy reading-bucket videos remain supported.

# Local worker verification — 2026-11-12

The integrated video/PDF extraction worker passes real native processing on this
PC. Hosted queue processing is not configured or started in this checkout.

| Component | Measured result |
| --- | --- |
| Worker unit/integration fixtures | 23 passed, no skips, using the new local venv |
| Native MP4 transcription | Passed through integrated process_one, FFmpeg and whisper.cpp; English speech, 2 timestamped segments |
| Whisper GPU execution | Confirmed CUDA0 backend on NVIDIA RTX 5060 Ti; process exited 0 |
| Whisper small model | SHA1 matches the existing documented model checksum |
| Selectable PDF | Passed through process_one and bounded subprocess adapter; text method, no page errors |
| Scanned PDF | Passed through the same path; real English OCR method, no page errors |
| Extraction/image/semantic SQL compatibility | 32 fixture tests passed, including migration 017 and private mentor files |
| Python dependency consistency | pip check passed |
| Supabase worker settings | Missing: no worker .env, URL or backend key in this checkout |
| Running extraction daemon | None; deliberately not started without target configuration |
| Hosted downloads, claims, saves and cron processing | Not exercised; no hosted requests or writes made |

## Local setup completed

Created `workers/content_analysis/.venv` with python-dotenv and PyMuPDF, and
Git-ignored junctions in this checkout for the existing standalone tools and OCR
data. The binaries/models remain in `C:\Users\PC\Documents\FYP\Content_Analysis_model`;
the original environment/project files were not changed. Native fixtures and
credential-free JSON results are under ignored `workers/content_analysis/output/worker-check`.
No real learner/resource media was used. No transcript or credential values were
printed by the diagnostic. Python 3.13.14, PyMuPDF 2.1 and python-dotenv 1.2.4
were installed/tested in this checkout's venv.

From `C:\Users\PC\Documents\FYP\SkillTrack - final`:

```powershell
# Safe local preflight: does not contact Supabase or claim jobs.
& '.\workers\content_analysis\.venv\Scripts\python.exe' -B '.\workers\content_analysis\speech-to-text\check_local.py'
# Real native smoke checks, reusing the generated synthetic speech fixture.
& '.\workers\content_analysis\.venv\Scripts\python.exe' -B '.\workers\content_analysis\speech-to-text\check_local.py' --video '.\workers\content_analysis\output\worker-check\fixture.mp4'
# All extraction tests, including the native PDF check that the global Python skipped.
& '.\workers\content_analysis\.venv\Scripts\python.exe' -B -m unittest discover -s workers/content_analysis/speech-to-text/tests -t workers/content_analysis/speech-to-text -v
```

## Still required for end-to-end processing

1. Configure the chosen integration Supabase project using the migration/bucket
   steps in MARKETPLACE_INTEGRATION.md. In particular, the canonical extraction
   RPCs, private bucket policies and migration 017 must exist on that target.
2. Copy speech-to-text/.env.example to its ignored .env. Set the integration
   SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY privately in that file. Do not paste
   the backend key into chat/source/Flutter. Point Flutter at the same project.
   Keep the documented legacy VIDEO_BUCKET/PDF_BUCKET configuration when those
   buckets exist; mentor-reading-files is also supported per source reference.
   The new tools/OCR junctions satisfy the default native paths on this PC.
3. Confirm image/Gemini analysis and gte-small semantic indexing functions, secrets
   and schedules on the target. These stages run on Supabase, not in the Python
   worker. Ordinary local Deno does not provide native Supabase AI inference.
4. Only after target configuration and authorization, launch the integrated worker
   from its own directory, using this checkout's venv (not an older project):

   ```powershell
   Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack - final\workers\content_analysis\speech-to-text'
   & '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker
   ```

   This command consumes hosted work and writes extraction results. It was NOT
   executed during this audit. `--once` also writes/claims jobs, so it is not a
   read-only diagnostic. Do not use either against a source/production project
   merely to check configuration.
5. On an isolated integration target, upload one authorized video, selectable PDF,
   scanned PDF and image; confirm extraction readiness, index creation, embedding
   readiness and authorized task recommendations. Check denied/unpaid access and
   file replacement/version invalidation with separate test accounts.

## Older local recommender

`C:\Users\PC\Documents\FYP\Recommendation_model\scripts\backfill.mjs`
uses `recommendation_resource_catalog`, `resource_embedding_queue` and the
`index-resources` endpoint. Those are its earlier standalone schema contract;
they are not this integrated application's extraction/index queue. Do not launch
that old backfill against the new integration. Its files were inspected only.
The active integrated flow is Python extraction -> resource_analysis_jobs ->
resource-analysis-queue Edge Function -> resource_index/resource_embeddings ->
recommend-resources. YouTube playback remains available, but this local file
worker does not download/transcribe YouTube URLs.
