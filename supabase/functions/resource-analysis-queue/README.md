# Automatic resource analysis

`resource-analysis-queue` is the single deployable resource-analysis function.
`generator.ts`, `gemini.ts` and `store.ts` now live here. The user-authenticated
manual endpoint and its standalone demo have been removed from the local source.
`test_helpers.ts` is an offline fixture; it is not imported by the entry point.
Notification and AI task-generation functions are unrelated and unchanged.

## What runs automatically

- Saving or meaningfully editing a published, non-hidden resource with a
  nonempty saved `body` queues text analysis in the same database transaction.
  Title, summary, category, body and existing tags form the source text.
- A Video waits for its **current uploaded file's ready transcript**. The ready
  trigger queues analysis atomically with transcript completion. Metadata
  changes and publication also queue current content. The backend validates the
  URL's configured project, bucket and stable Storage endpoint before using a
  transcript.
- One scheduled invocation backfills up to 25 eligible versions and claims at
  most one job. This handles existing published content without another upload.
  The scheduler continues when the Windows transcription PC is offline.
- A SHA-256 fingerprint covers the resource source fields and exact
  transcript/file version. Timestamp-only updates and repeated
  enqueue/completion do not duplicate jobs. Changed content gets separate work.
  Reverting to previously analysed content requeues its ready job only if a
  newer successful analysis replaced the index.
- Hidden/archived resources are excluded. Drafts require an explicit
  backend-only request for one UUID; ordinary triggers and scanning never
  enqueue all drafts.

`resource_analysis_jobs` remains the existing backend-only queue; migration 008
adds **one column, `content_version`**, and permits NULL transcript/file
identifiers for text jobs. It creates **no table** and preserves resource_index
and transcripts. Previous queue rows remain with `legacy:<id>` version markers
because they lack a saved metadata snapshot. Backfill queues current content
once; stale legacy claims are rejected/skipped without calling Gemini or
overwriting the index.

Claims use SKIP LOCKED and a 180-second lease, with at most three attempts.
Gemini has bounded retries, a 60-second analysis budget and bounded chunking
(120,000 characters maximum). Save and queue completion are atomic. Failed
analysis keeps the previous valid index. Failed jobs are not reset by discovery.
Replaced content and ineligible jobs are skipped. Index upserts retain the same
resource UUID.

## Coverage limitations

There is no verified uploader or saved PDF-extraction handoff in this checkout.
Non-video analysis requires text in `learning_resources.body`; a PDF/external
link with no saved body is deliberately not treated as analysed. This change
does not fetch arbitrary URLs, extract PDFs, send video files to Gemini, support
Cloudinary, or alter Flutter, Whisper, task generation, notifications or
recommendations. Connect the actual extractor to the saved body (or define a
verified saved-text contract) before claiming full PDF coverage. An existing
ready resource_index row alone does not prove that every newly uploaded file has
completed analysis.

## Security

Only POST with `x-resource-analysis-secret` is accepted. Set
`RESOURCE_ANALYSIS_CRON_SECRET` to a private random value of at least 32
characters. A public anon key or user JWT alone is insufficient. The body is
`{}` or `{"draftResourceId":"<uuid>"}`; owner IDs, content and transcripts are
rejected. Authors and source versions come from the database. SQL helpers and
queue RPCs are service-role-only. The resource AFTER trigger is SECURITY DEFINER
with a fixed search path and can enqueue only its own NEW resource, never
arbitrary client arguments. Existing resource RLS still controls the original
write. Queue RLS is retained, with no client table access.

## Operator rollout (not executed by this cleanup)

1. Install prerequisites 001-006 in order, including the real marketplace base
   schema. Keep historical migrations; do not delete 005/save_resource_analysis.
2. Pause an existing `resource-analysis-queue-every-minute` schedule while
   applying `008_automatic_resource_analysis.sql` and updating the function.
   Existing jobs and index data are preserved; no transcription is required.
   Migration 007's scheduler definition is unchanged and can be installed after
   008 on fresh setups.
3. Deploy **only resource-analysis-queue** for resource analysis, with the
   secrets below. Keep `[functions.resource-analysis-queue] verify_jwt = false`;
   the handler itself enforces the dedicated backend secret.
4. Set up/resume the scheduler and verify a real resource's current-version job
   and resource_index result. Only then retire any previously deployed
   `suggest-resource-tags` endpoint in the Supabase dashboard. Deleting its
   local folder does not remove a deployed function. No live deletion was
   performed.

Required Edge Function secrets/configuration:

- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (backend credentials)
- `GEMINI_API_KEY`
- `RESOURCE_ANALYSIS_CRON_SECRET`
- Optional `GEMINI_RESOURCE_TAG_MODEL` (default `gemini-3.5-flash-lite`)
- Optional `RESOURCE_VIDEO_BUCKET` (default `marketplace-videos`)

PowerShell from the repository root, after reviewing the target project:

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack'
npx supabase secrets set --env-file 'C:\private\resource-analysis.env' --project-ref gmefldljfeewdbkcoebm
npx supabase functions deploy resource-analysis-queue --project-ref gmefldljfeewdbkcoebm
```

Vault secrets for migration 007: `resource_analysis_url` is the project base
URL; `resource_analysis_cron_secret` is the same private secret as the Edge
Function. Update existing secrets rather than adding duplicate names. The cron
job runs `public.invoke_resource_analysis_queue()` every minute, with a
75-second HTTP request timeout. Missing Vault secrets cause invocation to do
nothing. Actual hosted pg_cron/pg_net delivery and Gemini availability/quota
need live verification.

## Test one saved draft without retranscribing or publishing

Load the private secret into your local environment, then use the backend
endpoint:

```powershell
$resourceId = 'ba0c9d09-17de-4542-957f-4a03c7e19f0b' # replace if needed
Invoke-RestMethod -Method Post -Uri 'https://gmefldljfeewdbkcoebm.supabase.co/functions/v1/resource-analysis-queue' -Headers @{ 'x-resource-analysis-secret' = $env:RESOURCE_ANALYSIS_CRON_SECRET } -ContentType 'application/json' -Body (@{ draftResourceId = $resourceId } | ConvertTo-Json)
```

Alternatively enqueue from SQL Editor with backend privileges, then let cron
drain:

```sql
select public.enqueue_ready_resource_analysis(
  'ba0c9d09-17de-4542-957f-4a03c7e19f0b'::uuid, true, 1);
```

Video still needs the current file's ready transcript. A draft job explicitly
created this way may subsequently be processed by the normal scheduler. Check:

```sql
select id, title, kind, status, moderation_hidden, external_url
from public.learning_resources
where id = 'ba0c9d09-17de-4542-957f-4a03c7e19f0b';

select id, content_version, transcript_id, source_file_id, source_version,
       status, attempt_count, error_code, next_attempt_at
from public.resource_analysis_jobs
where resource_id = 'ba0c9d09-17de-4542-957f-4a03c7e19f0b'
order by created_at desc;

select resource_id, keywords, topic_tags, analysed_at
from public.resource_index
where resource_id = 'ba0c9d09-17de-4542-957f-4a03c7e19f0b';
```

Success means the **current content version** is ready and resource_index
contains its labels. An idle result may mean backoff, an active claim, terminal
failure or unavailable content. Do not reset failed rows blindly or retranscribe
to retry Gemini.

## Offline verification

```powershell
deno test --no-lock supabase/functions/resource-analysis-queue/
deno check --no-lock supabase/functions/resource-analysis-queue/index.ts
deno lint supabase/functions/resource-analysis-queue/
node --test supabase/tests/resource_analysis_queue.test.mjs supabase/tests/resource_analysis.test.mjs supabase/tests/video_transcript_queue.test.mjs supabase/tests/video_transcription_discovery.test.mjs
```

SQL tests use local `@electric-sql/pglite` (or `PGLITE_MODULE` pointing to its
JS module). They execute the actual SQL on marketplace/storage schema fixtures,
not live Supabase. Scheduler extensions use stubs with no network requests.
PGlite serializes calls, so real multi-session lock contention remains a
deployment check. Tests cover text insert/update/backfill, video completion,
duplicates, content reversion/replacement, retries/leases, atomic rollback,
previous-result preservation, legacy data migration, RLS, backend
authentication, parsing and Gemini validation.

## Semantic indexing extension (migration 009)

After 009 is applied, this same backend endpoint also drains one resource
embedding alongside its existing analysis operation. It uses the same secret and
schedule; no local recommendation worker or additional cron job is needed.
Embedding errors are reported separately in `indexing` and do not undo analysis.
Deploy this function with `recommend-resources` after applying 009. See
[recommendation setup](../recommend-resources/README.md) for migration order,
backfill, verified access limitations and test-project checks. Existing analysis
behavior, Gemini configuration and Whisper transcription remain unchanged.
