# Cloud semantic recommendations (CLQ)

## Scope and actual contracts

This implementation uses `learning_resources` (UUID `id`) and `resource_index`
(UUID `resource_id`, text[] keywords/topic_tags, analysed_at). It does not
install the prototype's placeholder views or duplicate `resource_analysis`
table. `video_transcripts.resource_id` is text, joined to the real resource UUID
through migration 008's current-file candidates. Existing Whisper remains
upstream only.

One new table, `resource_embeddings`, holds vector(384), the original UUID
foreign key, source/indexed versions, model/text versions and indexing work
state. No new local worker or indexing queue table is added. Resource deletion
cascades to its vector. Indexing does not write task recommendations. Migration 015 adds current
recommendation sets; matching writes these only on demand or a stalled event.

The prototype's `gte-small` embedding, text construction, chunk pooling and
hybrid ranking were reused in `_shared/recommendations`. Native sessions are
created lazily in Supabase; ordinary Dart, Node and Deno cannot run that native
model. Both resource and task embeddings use the same model and text version.
Output is validated as 384 finite, nonzero dimensions. Text uses bounded
sections, chunks of 400 characters, mean pooling and L2 normalization. This
model is English-only; bounded text is not full-document comprehension.

Reference: https://supabase.com/docs/guides/functions/ai-models

## Access rules verified read-only on 2026-11-11

- Tasks belong to boards, boards to projects, projects to `owner_id`.
- Only an owned, active-project, unarchived, incomplete task can be recommended.
  Automatic requests additionally require a stalled task. Manual requests can
  use active non-stalled tasks. Neither mode changes the task.
- `learning_resources` has RLS enabled and authenticated SELECT privilege, but
  **currently has no SELECT policy**. That means authenticated users currently
  see zero resources. There is no verified purchase/enrolment table or
  marketplace resource-opening flow on CLQ. The marketplace video bucket is
  private.
- The endpoint pages resource IDs using `context.supabase`, the authenticated
  user client. Its actual RLS result is passed internally to the backend ranking
  RPC before scoring/LIMIT. The request cannot supply this list or an owner ID.
  Backend-only embedding tables and RPCs are not granted to authenticated users.
- After inference, task eligibility and user-visible display data are checked
  again. Hidden, archived, draft, inaccessible, changed and stale-source
  resources are excluded. No Storage URL, transcript, vector, service key or raw
  backend error is returned to Flutter.

**Deployment alone will not make the current catalog visible.** The marketplace
team must supply its intended authenticated read policies in the target project.
This change intentionally neither bypasses RLS with service-role visibility nor
adds a guessed public-read policy. With the current rules the UI shows the empty
state, which is the authorized result. Test positive matches using an authorized
fixture policy in a disposable project; do not loosen production policies to
test.

The teammate's future resource-details route can use the retained resource ID.
For now cards have title, summary and type only, without an Open button or URL.

## Indexing lifecycle and freshness

1. `complete_resource_analysis_job` atomically saves `resource_index` and marks
   the current analysis job ready. Migration 009 adds an AFTER ready trigger
   that enqueues the corresponding vector row in the same transaction.
2. `recommendation_index_sources` joins real catalog rows, current file
   candidates, ready analysis provenance and saved terms. A SHA-256 source
   version covers the current content version and extracted keywords/topic tags.
   Old analysis cannot index new content. Video replacement waits for its own
   ready transcript and successful analysis; Whisper is never called by
   recommendations.
3. The existing `resource-analysis-queue` function runs one analysis and one
   embedding drain independently in parallel. Its existing minute scheduler,
   backend secret and Vault settings are reused. Embedding failure does not undo
   analysis or cause another transcription. The response adds an `indexing`
   outcome.
4. Each invocation backfills up to 25 current missing/changed versions, then
   claims at most one embedding using FOR UPDATE SKIP LOCKED. Claims have
   180-second leases and three attempts with increasing minute backoff. Expired
   leases are reclaimed; final expiry/failure is terminal. Repeated backfill
   does not reset failed jobs.
5. Unchanged versions are skipped. Changes replace the target version and
   invalidate the old claim. The existing vector is retained but excluded from
   matching until a current-version save succeeds. Completion compares source
   version and token; a delayed worker cannot overwrite a replacement.
   Vector/ready state commit together.
6. Search independently joins the current source version. Missing callbacks
   cannot expose stale embeddings. Exact cosine/hybrid ranking filters access,
   freshness, technology compatibility and thresholds before its top-three
   limit.

Default thresholds/weights remain the prototype's provisional settings:
`RECOMMENDATION_MIN_SIMILARITY=0.65`, `RECOMMENDATION_MIN_SCORE=0.5`,
`RECOMMENDATION_SEMANTIC_WEIGHT=0.75`, `RECOMMENDATION_KEYWORD_WEIGHT=0.7`.
Framework/domain conflicts are excluded. Generic framework matches also require
keyword/topic overlap. Empty results are valid. Calibrate using real native
model outputs and a separate validation dataset before claiming recommendation
accuracy. No accuracy metric from fake vectors is presented as a
semantic-quality result.

## Migration and deployment (TEST PROJECT FIRST; not executed here)

1. Prepare a Supabase test project with the real SkillTrack and marketplace base
   schema, constraints and RLS, plus migrations 001-008. The base schema is not
   fully checked into this repository; do not initialize an empty project from
   009 alone.
2. Review and apply
   `supabase/migrations/009_semantic_resource_recommendations.sql` once. It
   enables pgvector in `extensions`, creates the vector/state table and
   real-source view/RPCs/trigger, and preserves all existing RLS policies. If
   vector already lives in another schema, it stops for review rather than
   moving it.
3. Deploy these two functions to the SAME test project from SkillTrack:

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack'
npx supabase functions deploy resource-analysis-queue --remote=YOUR_TEST_PROJECT_REF
npx supabase functions deploy recommend-resources --remote=YOUR_TEST_PROJECT_REF
```

The installed CLI uses `--remote`; use its `--help` if running a different
version. `recommend-resources` has `verify_jwt=false` in config because
`withSupabase({auth:
'user'})` performs authenticated-user validation. Disabling
gateway JWT verification is NOT permission to remove that middleware. This
endpoint does not accept the scheduler secret in place of a signed-in user's
token.

4. Reuse the existing `RESOURCE_ANALYSIS_CRON_SECRET`, Vault
   `resource_analysis_url` and `resource_analysis_cron_secret`, and cron job
   `resource-analysis-queue-every-minute` from 007. Test project values must
   point to the test project. No new recommendation scheduler or secret is
   needed. Native `gte-small` needs no external API key; Gemini is still used
   only by resource analysis.
5. Backfill from SQL Editor with backend privileges, or let cron discover work:

```sql
select public.backfill_resource_embeddings(100);
```

This only queues already analysed, published, non-hidden current sources. It
does not transcribe or call Gemini. The existing scheduler processes one
embedding per minute and continually reconciles up to 25 candidates, so no PC
needs to stay on.

Read-only checks:

```sql
select resource_id, status, attempt_count, error_code,
       source_version = indexed_version as current_vector,
       model_id, text_version, updated_at
from public.resource_embeddings
order by updated_at desc;

select jobname, schedule, active from cron.job
where jobname = 'resource-analysis-queue-every-minute';

select id, status_code, timed_out, error_msg, content, created
from net._http_response order by created desc limit 10;
```

A successful queue response can report analysis `idle` and indexing `ready`. For
failed embedding jobs inspect the error and model/runtime configuration first.
Retrying unchanged terminal failures is an explicit operator action; normal cron
never silently resets their attempt counts. Source changes automatically enqueue
fresh work. Old ready analysis without current-version provenance must finish
the normal analysis queue first, without retranscribing an already ready current
video.

## Authenticated endpoint and Flutter

POST `/functions/v1/recommend-resources` with the existing publishable `apikey`
and the signed-in user's Bearer access token. Existing callers may omit mode
(automatic stalled-only behavior). Manual requests accept only the saved task ID
and explicit mode, never title, description, owner or resource IDs:

```json
{ "task_id": "<owned incomplete task UUID>", "mode": "manual" }
```

Responses are `{status:"ok"|"empty"|"not_stalled", recommendations:[...]}`. Each
card is exactly `{resource_id,title,summary,type}`, maximum three. Invalid input
is 400, unauthenticated is 401, missing/unowned task is 404, a task edited while
inference ran is 409, and transient model/database failure is 503. Retries are
reads and never modify the task. No logging of user text or tokens is added.

The app injects `SupabaseRecommendationRepository` through
SkillTrackApp/AppRouter. The Task Details route owns/disposes
`TaskRecommendationsViewModel`. The ViewModel listens for task state, loads once
automatically per eligible stalled task context. Get Recommendations starts a
manual request for any eligible incomplete task, and stays available after a
success or empty response. Both modes share one pending-request guard and result
list; Retry repeats the failed mode. Task edits, completion, archive, project
ineligibility, sign-out/account change and disposal invalidate late responses.
Resume preserves the saved set. Migration 015 persists one current set (including
empty results); reopening reads it without matching. Refresh explicitly replaces it. The route uses the existing project repository to check active
project status; failure to verify this hides recommendations without blocking
other task actions. The backend independently rechecks ownership and eligibility
before and after inference. The widget displays only presentation state and uses
the shared Material theme.

## Local verification vs remaining checks

Offline tests use fake model outputs and local PGlite with pgvector. They
execute 001-006, 008 and 009 SQL on explicit marketplace/task/storage fixture
schemas. No live migrations, deployment, inference, model download or data
writes were done. The live database was inspected read-only to verify actual
columns/access rules. PGlite serializes calls: tests cover exclusive claims and
stale tokens, but actual multi-session contention must still be checked in a
Supabase test project.

Commands from SkillTrack:

```powershell
flutter analyze
flutter test
deno test --no-lock supabase/functions/recommend-resources supabase/functions/resource-analysis-queue
deno check --no-lock supabase/functions/recommend-resources/index.ts supabase/functions/resource-analysis-queue/index.ts
deno lint supabase/functions/_shared/recommendations supabase/functions/recommend-resources supabase/functions/resource-analysis-queue
node --test supabase/tests/semantic_recommendations.test.mjs
```

SQL tests need locally installed `@electric-sql/pglite` and
`@electric-sql/pglite-pgvector`, or PGLITE_MODULE/PGVECTOR_MODULE set to their
module paths. In this workspace the existing Recommendation_model/node_modules
provides both; no new packages were added to SkillTrack.

Test-project acceptance checks still required:

- Native gte-small inference/CPU limits, cold start and actual semantic quality.
- A signed-in owner with an eligible stalled task versus a second unauthorized
  user.
- Approved marketplace read policies granting the intended user access to a
  relevant resource and an unrelated resource; verify only relevant results
  clear thresholds.
- Hide the relevant resource and confirm it immediately disappears; also test a
  resource denied specifically to that user before ranking.
- Replace a video file and verify the old vector is excluded until new
  transcription, analysis and indexing complete. Do not rerun Whisper merely to
  backfill vectors.
- App/device smoke test: loading, empty, error retry, no repeat calls on
  rebuild, resume preserves saved cards; no URLs or Open button and other task
  actions unchanged.
- Confirm existing analysis/notification cron jobs continue operating after
  deployment.

## Changed files and executed results

Added:

- `supabase/migrations/009_semantic_resource_recommendations.sql`
- `supabase/tests/semantic_recommendations.test.mjs`
- `supabase/functions/_shared/recommendations/http.js`
- `supabase/functions/_shared/recommendations/indexer.ts`
- `supabase/functions/_shared/recommendations/runtime.ts`
- `supabase/functions/_shared/recommendations/semantic.js`
- `supabase/functions/_shared/recommendations/terms.js`
- `supabase/functions/recommend-resources/index.ts`
- `supabase/functions/recommend-resources/handler.ts`
- `supabase/functions/recommend-resources/store.ts`
- `supabase/functions/recommend-resources/handler.test.ts`
- `supabase/functions/recommend-resources/README.md`
- `lib/features/learning_integration/models/resource_recommendation.dart`
- `lib/features/learning_integration/repositories/recommendation_repository.dart`
- `lib/features/learning_integration/repositories/supabase_recommendation_repository.dart`
- `lib/features/learning_integration/view_models/task_recommendations_view_model.dart`
- `lib/features/learning_integration/widgets/task_recommendations_section.dart`
- `test/features/learning_integration/task_recommendations_test.dart`

Updated:

- `lib/main.dart`
- `lib/app/skill_track_app.dart`
- `lib/app/router/app_router.dart`
- `lib/core/errors/app_exception.dart`
- `lib/features/kanban/widgets/task_details_sheet.dart`
- `supabase/config.toml`
- `supabase/functions/resource-analysis-queue/index.ts`
- `supabase/functions/resource-analysis-queue/README.md`

Executed on CLQ:

- Dart formatting and `flutter analyze`: no issues.
- Full `flutter test`: 457 passed.
- Recommendation and existing analysis-queue Deno tests: 27 passed.
- Deno formatting, lint and both entry-point type checks: passed.
- Local PGlite/pgvector regression tests: 51 passed across semantic
  recommendations, resource analysis, analysis queue, transcription queue and
  video discovery. This includes 12 semantic recommendation database tests.
- `git diff --check`: passed.

These are local correctness/regression results, not live deployment or
native-model accuracy measurements. The test-project acceptance checks above
remain outstanding.

## Manual Get Recommendations rollout

Apply `supabase/migrations/010_manual_task_recommendations.sql` after 009, then
redeploy **only `recommend-resources` for this incremental feature**:

```powershell
npx supabase functions deploy recommend-resources --remote=YOUR_TEST_PROJECT_REF
```

Migration 010 adds mode-aware overloads and keeps the original SQL signatures as
automatic-mode wrappers. It adds no tables or columns, changes no RLS policies,
and performs no task writes. Old endpoint requests without `mode` remain
compatible; unsupported modes and extra input fields are rejected. The new
Flutter client sends `mode: manual` or `mode: automatic` alongside `task_id`.

If the earlier semantic recommendation implementation is not installed yet,
install 009 before 010 and deploy its updated `resource-analysis-queue` too, as
described above. This manual-action change does not alter that function, the
scheduler, embedding generation, thresholds or resource visibility rules.

Manual feature files changed:

- `lib/features/learning_integration/repositories/recommendation_repository.dart`
- `lib/features/learning_integration/repositories/supabase_recommendation_repository.dart`
- `lib/features/learning_integration/view_models/task_recommendations_view_model.dart`
- `lib/features/learning_integration/widgets/task_recommendations_section.dart`
- `lib/features/kanban/widgets/task_details_sheet.dart`
- `lib/app/router/app_router.dart`
- `supabase/functions/recommend-resources/handler.ts`
- `supabase/functions/recommend-resources/store.ts`
- `supabase/functions/recommend-resources/handler.test.ts`
- `supabase/functions/recommend-resources/README.md`
- `supabase/migrations/010_manual_task_recommendations.sql`
- `supabase/tests/semantic_recommendations.test.mjs`
- `test/features/learning_integration/task_recommendations_test.dart`

Device smoke test after deployment: open a non-stalled To-Do/In Progress task,
tap Get Recommendations, verify loading and disabled repeat taps, then inspect
cards/empty state. Tap again to refresh. Verify Retry after a connection
failure. Open a stalled task to confirm automatic generation, Resume Task to
preserve saved results, then explicitly refresh. Complete or archive a task and
confirm refresh is disabled while saved cards remain readable. No history,
bookmark or task progress changes should occur.

Manual feature validation (executed locally on CLQ):

- `flutter analyze`: no issues; full Flutter suite: **464 passed**, including
  **13** focused recommendation tests.
- Recommendation and analysis-queue Deno tests: **31 passed**, including mode
  forwarding to both real store RPC calls.
- Local PGlite/pgvector semantic database tests through migration 010: **14
  passed**. Existing automatic signatures, ownership, current embeddings,
  visibility, manual eligibility and absence of task writes are covered.
- Dart/Deno formatting, Deno type checking/lint, and `git diff --check` passed.
- No live migrations, function deployments, native-model calls or device smoke
  tests were performed for this incremental feature. Marketplace read policies
  and ready current-version embeddings remain prerequisites for nonempty
  results.


## Persistent task recommendations — migration 015

Two small tables keep one current generation per task: `task_recommendation_sets`
records success (including empty results), stalled period, model/text provenance
and a short claim lease; `task_recommendation_items` records up to three ordered
resource IDs and matched source versions. No resource content is duplicated.
Bookmarks remain in their independent table.

- Flutter first calls authenticated `task_recommendations`. Current marketplace
  RLS, published state and moderation are checked on every read. Metadata is
  current; hiding/deleting resources yields fewer cards, not another search.
  There is no catalog realtime subscription: an already-open screen reloads on
  reopening or task-state changes, not instantly upon a remote catalog change.
- First stalled generation and a new `stalled_at` episode generate automatically.
  A manual generation during that period also satisfies its automatic generation.
  An existing successful empty generation is reusable. Resume keeps saved items.
- Refresh uses a backend-only claim, then one transaction replaces all items.
  A 90-second lease excludes concurrent matching. Final task/version, resource
  freshness and recipient access checks reject stale completion. Failure retains
  the last successful set. An abandoned lease can be reclaimed after expiry.
- Repeating completion with the same claim token returns the saved result. If
  the entire HTTP response is lost, reopening recovers it. A later explicit
  manual Refresh is a new operation (and can perform another embedding call).
- Cron uses the same persistence path before notification enqueue, independent
  of notification preferences. Existing notification deduplication and fallback
  remain intact. A failed generation can retry on a later cron run even if a
  generic stalled alert was already sent; it will not send a second alert for
  that episode. Embedding calls retain the existing timeout and invocation budget.
- Persisted provenance records the version originally matched. Saved reads do
  not claim it was matched against later content. Explicit refresh uses current
  embeddings; notification enqueue still rejects stale resource provenance.

### Deployment order (not executed by this change)

1. Verify the canonical base schema and existing migrations through 014,
   especially 011 recipient RLS helpers, 012 ownership helper/bookmarks, and
   013/014 extraction/current-source views. Do not recreate existing tables.
2. Run `supabase/migrations/015_persistent_task_recommendations.sql` once in
   Supabase SQL Editor (or the project's migration process).
3. From the project root:
   ```powershell
   npx supabase functions deploy recommend-resources
   npx supabase functions deploy project-notification-generator
   ```
4. Rebuild/run Flutter. No new secret, scheduler, Storage bucket, embedding
   backfill, or resource-analysis deployment is required. Existing cron and
   marketplace read policies must already work.

Rollback: redeploy the previous Edge Functions/client; leave the additive
storage in place. Do not drop saved data. Existing unmodified matching RPCs
remain available to the older functions.

### Acceptance test in an authorized test project

1. On an incomplete task, Get Recommendations; check the ordered cards and
   generation row. Close/reopen Task Details (and restart the app): same set,
   no new embedding request. Repeat with an intentionally empty eligible catalog.
2. Publish/analyse/index a new relevant resource. Reopening alone keeps the set;
   Refresh can include it. Simulate a request failure: previous cards stay.
3. Bookmark one card, then refresh to empty. The bookmark remains. Resume the
   task: saved cards remain. A later genuine stalled period can replace them.
4. Hide a saved resource or revoke its read policy, then reopen: it is absent.
   Another account cannot read or generate for this task.
5. Run existing notification cron with a dedicated test task. Confirm the set
   is saved before a resource alert, tapping loads it, and rerunning sends no
   duplicate. Check fallback and both category preferences separately.

### Local verification limits

SQL tests use PGlite with the actual applicable migrations and a minimal base
schema/RLS fixture. They test rollback, serialized duplicate claims, stale
completion, lost-response completion, empty sets, access checks and bookmark
preservation. PGlite is not evidence of multi-connection hosted concurrency,
production marketplace policies, native gte-small quality, cron or Android push.
Those still need the acceptance test above against the target deployment.
