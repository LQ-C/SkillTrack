> Updated extraction flow: see `workers/content_analysis/EXTRACTION_ROLLOUT.md`
> from the repository root. Migration 013 unifies video and private Reading PDFs.
> Older video-only descriptions below document the compatibility baseline.

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

## Direct image analysis (migration 014)

The confirmed image contract is **Reading + external_url + the existing private
marketplace-documents bucket**, shared with PDFs. No new marketplace kind, table,
public bucket, image asset, or Python image worker is introduced. Only the
resource's primary external_url is considered; thumbnails, avatars and task
attachments are not scanned. The actual uploader is not present on CLQ. It must
finish the Storage upload, set its correct MIME metadata, and save a stable
same-project `/storage/v1/object/authenticated/marketplace-documents/<path>` link
(or the existing `/public/` reference form; downloads still use authentication).
Signed/expiring links, arbitrary URLs and Cloudinary are rejected.

Normal cron discovers up to 25 new file versions and processes at most one image
per invocation, alongside one ordinary analysis and one embedding. Discovery
requires both the published, non-hidden Reading row and a committed Storage
object. Existing files are backfilled by that same discovery. Storage metadata
and extensions identify candidates; both metadata/HTTP MIME and the actual PNG
or JPEG container are checked before sending bytes to Gemini. Downloads bypass
cache and use If-Match plus response ETag comparison when Storage supplies an
ETag; the final transaction always rechecks the object UUID/version. Verify the
actual Storage metadata/response headers in the acceptance test. Prefer immutable
upload paths if the uploader cannot supply a reliable version/ETag. Other Reading
links retain authored-body analysis; PDFs retain the local extractor. Unclear
images may produce a factual uncertainty description and empty label arrays;
there is no invented OCR text fallback.

Limits: 5 MiB compressed image, at most 8192 pixels on either side and 16 million
pixels total; PNG/JPEG only (no animated PNG). Download timeout 10 seconds,
Gemini request timeout 15 seconds with at most two transient attempts, bounded
64 KB provider response, 60-second image operation, 180-second claim lease.
Descriptions are limited to 4000 characters, keywords to 20 and topic tags to 8.
The container is inspected without decoding pixels; corrupt compressed content
which passes container inspection must still be accepted by Gemini before saving.
No bytes, credentials or document content are written to logs or PostgreSQL.

`resource_extractions.extraction_type = 'image_description'` reuses the existing
status/attempt/claim/lease fields and unique resource/file/version key. Completion
atomically saves `extracted_text`, labels in resource_index and a ready receipt
in resource_analysis_jobs. Its existing ready trigger queues semantic indexing.
It does not enqueue a second Gemini call for the just-completed image. Metadata
changes can use ordinary text reanalysis with the saved current description.
Previous valid results survive failed saves; replacement immediately makes old
analysis/vectors ineligible. Successful unchanged files are not analysed again.
Three work attempts are permitted; terminal failures are not reset by discovery.
A response lost after commit is safe to retry with the original claim token.

The description is placed first in the existing embedding **Description** field,
followed by summary/category. The existing gte-small model, chunking, pooling,
limits and text-version `skilltrack-v1-chunk400-mean-l2` are unchanged. Non-image
embedding inputs are unchanged, so they need no model/text-version backfill.
Image source fingerprints include the description and exact Storage version;
the existing embedding queue handles new images and replacements automatically.
Recipient RLS, matching thresholds, bookmarks and notification rules are unchanged.

### Deployment order (prepared only; not executed)

1. Ensure the existing marketplace schema and migrations 001–013 are already
   applied. Back up and review the deployed definitions. Apply only the new
   `supabase/migrations/014_resource_image_analysis.sql` in SQL Editor, as one
   transaction. It extends the extraction-type CHECK and replaces only the
   dependent source/analysis view/functions; it preserves RLS and service-only
   access. Do not rerun the historical rename migration 013.
2. Keep marketplace-documents **private**. If the bucket has an allowed MIME list,
   preserve application/pdf and add image/png and image/jpeg. Confirm its upload
   limit permits the chosen image (the Edge limit remains 5 MiB). No bucket or
   policy change has been performed by this implementation.
3. Set backend configuration from the repository root:

   ```powershell
   npx supabase secrets set RESOURCE_IMAGE_BUCKET=marketplace-documents GEMINI_RESOURCE_IMAGE_MODEL=gemini-3.5-flash-lite
   ```

   Keep the existing GEMINI_API_KEY and RESOURCE_ANALYSIS_CRON_SECRET. The image
   model falls back to GEMINI_RESOURCE_TAG_MODEL, then gemini-3.5-flash-lite.
   This pipeline uses native Gemini REST, not a new SDK/package. Google's
   [model documentation](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite)
   lists image input and structured output; [inline image data](https://ai.google.dev/gemini-api/docs/image-understanding)
   is sent as base64 inlineData, never as a public image URL. Model availability,
   quotas and actual extraction quality still require a real API check.
4. Redeploy **only resource-analysis-queue**:

   ```powershell
   npx supabase functions deploy resource-analysis-queue
   ```

   Keep its existing `verify_jwt=false` configuration: the dedicated secret
   authenticates this backend endpoint. No changes to recommend-resources or
   notification Edge Functions are required. Keep the existing minute scheduler
   and Vault secrets `resource_analysis_url` and `resource_analysis_cron_secret`.
   No extra cron job is needed. Python workers can keep their current commands;
   their claim/discovery RPCs never return image work.
5. Let the next scheduled invocation discover existing published images. The
   embedding may run on the following invocation because draining is parallel.

### Acceptance test with one real image

1. In a test project, upload a legible Flutter widget hierarchy PNG/JPEG under
   a unique path in marketplace-documents using the authorized uploader. Use
   correct image MIME metadata and leave the bucket private. Create/link one
   owned Reading resource with that stable URL, status published and
   moderation_hidden=false. Stop the local worker to demonstrate images need
   no PC. Wait for two or more scheduler ticks.
2. Alternatively test **one draft** without publishing or scanning other drafts:

   ```powershell
   $resourceId = 'REPLACE_WITH_RESOURCE_UUID'
   Invoke-RestMethod -Method Post -Uri "$env:SUPABASE_URL/functions/v1/resource-analysis-queue" -Headers @{ 'x-resource-analysis-secret' = $env:RESOURCE_ANALYSIS_CRON_SECRET } -ContentType 'application/json' -Body (@{ draftResourceId = $resourceId } | ConvertTo-Json)
   ```

   Populate these environment variables privately; do not paste the secret into
   chat or logs. The draft ID is the only caller data accepted. For draft retries,
   invoke with that same ID after next_attempt_at; normal cron does not claim
   draft image work. Drafts remain excluded from recommendations until published.
3. Inspect state using this read-only SQL (replace the UUID):

   ```sql
   select e.id, e.resource_id, e.extraction_type, e.status, e.attempt_count,
          e.error_code, e.source_file_id, e.source_version,
          e.extracted_text, i.keywords, i.topic_tags, i.analysed_at,
          v.status as embedding_status,
          (s.source_version = v.indexed_version) as embedding_is_current
   from public.resource_extractions e
   left join public.resource_index i on i.resource_id::text = e.resource_id
   left join public.recommendation_index_sources s on s.resource_id = i.resource_id
   left join public.resource_embeddings v on v.resource_id = i.resource_id
   where e.resource_id = 'REPLACE_WITH_RESOURCE_UUID'
   order by e.created_at desc;
   ```

   Expect image_description/ready, a factual saved description, relevant labels
   and eventually a ready/current embedding for a published resource. Confirm
   the resource's authored body and summary are unchanged. Compare the description
   against the actual image; JSON validity is not proof of factual accuracy.
4. Invoke again: extraction IDs/attempt count and analysed_at remain unchanged.
   Request recommendations for a relevant saved task; results still depend on
   the existing relevance threshold and the signed-in user's marketplace access.
   Hide the resource and confirm it disappears. Replace the file (new Storage
   version), then confirm no old result is matched while the new one is pending.
5. Test a malformed PNG, MIME mismatch, oversized image and missing file using
   dedicated test resources. No partial description/labels should replace a valid
   result. Test a temporary provider failure and recovery after next_attempt_at.

Recovery: fix configuration/provider/file issues first. A backend administrator
may explicitly reset only a failed image row's status to pending, attempt_count
to zero and next_attempt_at to now; clear claim_token/lease_expires_at/error_code.
Do not reset a processing/ready row or unrelated work. Prefer a new upload version
for corrected files. To stop cloud images, revert the Edge deployment while
leaving migration/data in place; existing video/PDF workers continue. Do not drop
image rows or restore the old extraction-type constraint over saved image data.

### Image verification and limits

```powershell
deno test --no-lock supabase/functions/resource-analysis-queue/ supabase/functions/recommend-resources/handler.test.ts supabase/functions/project-notification-generator/generator.test.ts supabase/functions/project-notification-generator/recommendations.test.ts
node --experimental-transform-types --test supabase/functions/project-notification-generator/index.test.ts
deno check --no-lock supabase/functions/resource-analysis-queue/index.ts
deno lint supabase/functions/resource-analysis-queue/
node --test supabase/tests/resource_images.test.mjs supabase/tests/resource_extractions.test.mjs supabase/tests/resource_analysis_queue.test.mjs supabase/tests/resource_analysis.test.mjs supabase/tests/semantic_recommendations.test.mjs
```

Local SQL tests require PGLITE_MODULE and PGVECTOR_MODULE or installed PGlite and
pgvector packages. They run the real migrations against local schema fixtures,
not the missing canonical marketplace DDL. Image/provider tests use tiny real
PNG/JPEG containers and fake downloads/Gemini; vectors are synthetic. They do not
verify hosted Storage delivery, real Gemini understanding, native gte inference,
production RLS configuration, or multi-session PostgreSQL lock contention.

Executed locally for this change: 29 resource-analysis Deno tests (11 image
checks), 58 recommendation/stalled-generator Deno regression tests, 7 Node
notification adapter tests, 47 SQL fixture tests and 22 Python worker tests passed.
The final image/extraction SQL subset (9 tests) was rerun after the ETag addition.
Deno production check/lint, formatting, git diff --check and flutter analyze passed.
An initial attempt to run the Node adapter test under Deno failed because its
Node module hooks do not replace Deno.serve there; its documented Node runner
passed all 7 tests. No hosted Gemini/native embedding or live migration was run.
