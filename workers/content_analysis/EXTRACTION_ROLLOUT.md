# Unified video/PDF extraction: migration 013

## Verified contract and scope

Project owner confirmed Reading + external_url + private marketplace-documents.
Only stable public/authenticated Supabase Storage URLs ending in .pdf in that
bucket qualify. Video keeps its configured VIDEO_BUCKET. Signed URLs, arbitrary
hosts, Cloudinary, YouTube and other Reading links are never downloaded.
Other saved-body resources retain their existing analysis path. No authored body
is overwritten. No Flutter, task-generation, notification, bookmark or ranking
code is changed.

The canonical marketplace base DDL/live deployment was not available for this
change. UUID learning_resources.id and text extraction resource_id are preserved
according to the current checked-in caller contract and owner confirmation.
Opaque legacy resource IDs remain stored unchanged; they are not cast to UUID.
They cannot be linked to a marketplace UUID unless a separate reviewed mapping
exists. No such mapping is invented here.

## Storage and compatibility

013_resource_extractions.sql renames the existing physical table and text column
in one transaction. IDs, content, status, attempts, active claim tokens, leases,
unique keys, original constraints, RLS, grants, triggers and FK targets survive.
extraction_type defaults to video_transcript for existing rows; new PDFs use
pdf_text. There is no second extraction or job table.

video_transcripts is now a temporary security-invoker compatibility VIEW with
transcript_text aliased from extracted_text. Only service_role can access it.
Old video claim/renew/complete/fail RPCs stay callable; old claim only returns
video work. The new worker calls resource_extraction_candidates,
enqueue_discovered_extraction, claim_resource_extraction,
renew_resource_extraction, complete_resource_extraction and fail_resource_extraction.
Old enqueue_video_transcription writes the renamed physical table directly;
ON CONFLICT is never attempted against the compatibility view.

resource_analysis_jobs.transcript_id and p_transcript parameter names remain
compatibility aliases for an extraction ID/JSON, now including PDFs. Their
foreign key points to resource_extractions automatically. Renaming those APIs
would unnecessarily break deployed jobs/functions. Existing video fingerprints
remain identical; existing ready video text is not retranscribed or invalidated.

The ready trigger still feeds enqueue_video_analysis (historical function name),
which resolves the generalized current-file candidates. The same atomic queue
completion saves resource_index and queues embeddings. PDF source text is exposed
as pdf_text to the unchanged embedding builder; video text remains transcript.
Old analysis deployments reject PDF-source jobs rather than save title-only
results, because their missing extraction provenance fails validation. Deploy
analysis before starting PDF work to avoid those jobs being marked skipped.

Do not remove compatibility objects yet: saved SQL functions, migration 011 and
older workers still use them. A later cleanup needs a full deployed dependency
inventory. Historical migrations are intentionally unchanged.

## Rollout order (not executed)

1. Back up the test database. Confirm the real base marketplace/task schema and
   existing migrations 001-012 are installed in their established order (007
   scheduler requires pg_net/cron/Vault; 009 requires pgvector). On a fresh
   database install that baseline first, then 013; do not start with 013 alone.
2. Review and run the ENTIRE supabase/migrations/013_resource_extractions.sql in
   SQL Editor. It takes a transactional table lock. Do not split statements or
   use CASCADE to bypass an unexpected dependency. A failure rolls back the rename.
3. Keep existing GEMINI_API_KEY, RESOURCE_ANALYSIS_CRON_SECRET, resource_analysis_url,
   resource_analysis_cron_secret and every-minute scheduler unchanged. Configure
   RESOURCE_PDF_BUCKET=marketplace-documents in the analysis Edge environment
   (this is also the default; do not point it at an unverified bucket).
4. From SkillTrack deploy only the changed function to the selected TEST project:

```powershell
npx supabase functions deploy resource-analysis-queue --remote=YOUR_TEST_PROJECT_REF
```

5. Stop the old local worker gracefully, update its code/environment, then restart
   with the commands below. Old video workers can finish valid claims during the
   rollout; the new completion rechecks current object identity and visibility.
6. Run backfill/acceptance checks before scheduling production use. No migration
   or deployment was performed by the implementation task.

## Windows environment and commands

Use absolute paths for WHISPER_CPP_EXE, WHISPER_CPP_MODEL and FFMPEG_EXE; these
existing binaries/models stay outside Git. Keep real .env and backend credentials
private. The Python worker .env needs:

```text
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_SERVICE_ROLE_KEY=YOUR_PRIVATE_BACKEND_KEY
VIDEO_BUCKET=YOUR_EXISTING_VIDEO_BUCKET
PDF_BUCKET=marketplace-documents
TESSDATA_PREFIX=C:\path\to\Tesseract-OCR\tessdata
PDF_EXTRACT_TIMEOUT_SECONDS=600
```

TESSDATA_PREFIX must contain eng.traineddata. No model download is automatic.
MAX_VIDEO_MB is the existing download-size limit and now applies to both types.
PDF_EXTRACT_TIMEOUT_SECONDS accepts 1-7200; default 600. Processing errors are
safe codes: pdf_invalid, pdf_encrypted, pdf_empty, pdf_ocr_failed,
pdf_extraction_failed, download_failed, save_failed. Three attempts use the
existing backoff; failed discovery never resets terminal failures. OCR errors
fail the document instead of silently indexing incomplete text.

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack\workers\content_analysis'
# Reuse your private venv, or create this ignored environment once:
py -m venv .venv
& '.\.venv\Scripts\python.exe' -m pip install -r '.\speech-to-text\requirements.txt'
Set-Location '.\speech-to-text'
# Put the private worker .env here, or set variables in this process.
& '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker --once
& '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker
# Explicit draft discovery: no scan of all drafts.
& '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker --once --draft-resource-id RESOURCE_UUID
```

--once discovers a bounded page and processes at most one eligible queued item.
As with the existing worker, draft targeting restricts discovery, not the shared
claim queue: other queued work can be processed first. Successful continuous
processing immediately checks for more work; idle/errors retain the poll delay.
Temporary inputs and extracted-text output are removed after success/failure;
force-killing the OS process may leave OS temp files requiring local cleanup.

## What runs where

PC: discovery, private authenticated Storage download, Whisper/FFmpeg for videos,
PyMuPDF/Tesseract for PDFs, periodic lease renewal. PC must be running for new
extraction work. No private file or extracted text is logged.
Supabase: extraction state/RPCs, atomic ready-to-analysis trigger, analysis queue,
scheduled Gemini keyword/topic extraction, resource_index and semantic indexing.
These continue after the PC stops once extraction is ready.

## Verification / recovery

```sql
-- Read-only: physical storage, legacy view, counts and retained ID type.
select c.relname,c.relkind from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('resource_extractions','video_transcripts');
select extraction_type,status,count(*) from public.resource_extractions group by 1,2;
select data_type from information_schema.columns where table_schema='public'
  and table_name='resource_extractions' and column_name='resource_id';
```

For a dedicated test PDF: upload the object completely, create/publish its Reading
resource with the matching stable authenticated URL, run --once, then check
resource_extractions by resource_id::text, resource_analysis_jobs by resource UUID,
resource_index and resource_embeddings. Check authored body is unchanged. Repeat
--once to prove no duplicate extraction. Replace the Storage object and verify
old provenance disappears from recommendation_index_sources before new extraction.
For a draft, use the explicit worker flag and then the backend-only analysis
endpoint's existing draftResourceId test request; drafts remain excluded from
recommendations. Normal ready backfill uses:

```sql
-- Backend-only test operation, not a read-only verification query.
select public.enqueue_ready_resource_analysis();
select public.backfill_resource_embeddings();
```

If migration fails, its transaction leaves the old schema intact. If worker or
analysis rollout fails, stop the NEW worker and roll back the application binaries;
keep migration 013 and compatibility objects. Old video workers still operate;
PDF rows remain pending/ready safely. Expired claims are recoverable automatically
until their attempt limit. Do not drop the table, delete failed rows, reset all
claims or reverse-rename after new PDF writes. Repair the cause and perform a
reviewed, targeted retry for the affected failed/skipped version if needed.

Tests use local schema fixtures rather than the complete production baseline.
Whisper, Gemini, native embeddings and real OCR were not executed. A real text PDF
and encrypted/malformed PDF handling were exercised with installed PyMuPDF; the
scanned-page OCR branch uses fake pages. Full provider/device/live RLS and true
multi-session concurrency verification still require a test project.

## Executed checks and files

- Existing Python baseline: 17 tests passed. Updated worker suite: 22 passed.
- Full local SQL regression suite: 203 passed. The 3 unified-extraction tests were
  rerun after the final claim eligibility change and passed.
- Deno analysis/recommendation/stalled-generator regression suites: 76 passed.
- resource-analysis-queue production type check and Flutter analyze: passed.
- No live provider or real OCR inference was executed; no migration/deploy/commit/push.

Changed files:
- supabase/migrations/013_resource_extractions.sql (new)
- supabase/tests/resource_extractions.test.mjs (new)
- supabase/functions/resource-analysis-queue/{index,processor,store,generator.test}.ts
- supabase/functions/resource-analysis-queue/README.md
- workers/content_analysis/speech-to-text/skilltrack_speech/{config,supabase_gateway,worker}.py
- workers/content_analysis/speech-to-text/skilltrack_speech/pdf_adapter.py (new)
- workers/content_analysis/speech-to-text/tests/test_discovery.py
- workers/content_analysis/speech-to-text/tests/test_pdf_worker.py (new)
- workers/content_analysis/speech-to-text/{requirements.txt,.env.example,README.md}
- workers/content_analysis/EXTRACTION_ROLLOUT.md (new)

The existing cloud analyzer still rejects combined source text above 120,000
characters and uses its existing request timeout/chunk budget. Full extraction
text remains stored even when that downstream limit is exceeded. This change
connects extraction; it does not remove the provider's existing processing bounds.
