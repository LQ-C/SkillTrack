# Stalled-task resource recommendation alerts

## Delivery rule

The existing hourly Project Notification Generator updates dynamic stagnation as
before. For a current stalled period it first checks whether an alert has
already been saved. If recommendation notifications are enabled, it attempts the
shared semantic matcher. A relevant accessible resource produces exactly one
`LEARNING_RESOURCE_RECOMMENDATION` notification with `RECOMMENDATION` context.
Otherwise the existing `STALLED_TASK` alert is the fallback, only when that
category is enabled. Deadline reminders are independent.

**One of these two categories is saved per user/task/stalled period.** Once the
fallback has been delivered, a later scheduled run does not also send a resource
alert for that period. Resume/meaningful progress followed by a later stalled
period permits another alert. An already-delivered old stalled alert also blocks
a second alert in the same period. There are no hourly/daily recommendation
keys.

The final RPC locks the task, rechecks owner, active project/board, task status,
persisted `stalled_at`, profile, current preferences, source version, ready
vector and recipient access, then calls the existing `enqueue_app_notification`.
Both notification categories share that lock. Repeating a commit after a lost
response cannot create an additional row or change its category. Existing unique
keys remain the final insertion guard. No history, bookmark or queue table is
added.

Each task has at most one matching attempt per invocation. Native inference is
bounded to five seconds; the whole matching attempt is bounded to ten seconds,
within a 45-second matching budget for the scheduled run. Remaining tasks use
the normal fallback. Failed inserts may retry on the next hourly run, with the
same persisted period and a fresh eligibility check. If no fallback is enabled
and no alert was saved, a later run can try matching again. There is no
unbounded retry loop and no additional Gemini call. A slow/cold native model can
result in a fallback; calibrate this in a test project before claiming
recommendation coverage.

## Authorization

The authenticated `recommend-resources` endpoint still requires a user token and
supports automatic/manual modes. Both it and the scheduler call the same shared
matcher. The cron endpoint continues to require
`PROJECT_NOTIFICATION_CRON_SECRET`.

Cron does not use a service-role catalog SELECT as a substitute for user access.
Migration 011 adds a small reader owned by the non-bypass `authenticated` role,
with pinned search path, which executes the actual marketplace RLS policies. It
accepts resource IDs only, never an arbitrary recipient. A separate backend-only
wrapper installs the recipient's `auth.users` identity/metadata claims, calls
that reader, and restores the previous claims on success or failure. Browser
clients cannot invoke the recipient-substitution wrapper or notification enqueue
RPC. The migration refuses a reader role that would bypass RLS. No marketplace
read policy or table access grant is added.

Offline access uses the recipient's database identity, app/user metadata and
`aal1`; it cannot manufacture a logged-in device session, MFA proof, or custom
access-token-hook claims. Policies requiring those claims must be reviewed with
the marketplace team; ordinary auth.uid()/metadata policies are exercised in
local tests. With no applicable marketplace SELECT policy, matching is empty and
the ordinary stalled alert is used. This is intentional and must not be fixed by
disabling RLS. PostgreSQL behavior is documented at:
https://www.postgresql.org/docs/17/ddl-rowsecurity.html

## Existing push pipeline and navigation

The existing notifications INSERT webhook invokes
`project-push-notification-dispatcher`. It already supports this category,
`recommendation_enabled` and the separate opt-in `push_enabled` preference.
There is no direct FCM send from the generator. The existing notification UUID,
Android tag/collapse key, foreground display guard and tap guards are retained.
A retry reuses the same notification identity; FCM delivery itself is not an
exactly-once protocol. Real device retries and notifications after app restarts
still need verification.

Payloads contain the existing notification/user/task context only. The in-app
row's small action data contains a resource UUID, period and section name, with
no Storage URLs, transcript, vector or credential. Push navigation reloads the
notification through the current user's repository, then uses the same
NotificationListViewModel destination validation as an in-app tap. Both routes
open existing Task Details focused on Learning resources. Cards show current
accessible title, summary and type. If the task was resumed, tapping the
resource notification explicitly requests manual recommendations;
completed/archived tasks do not receive new recommendation requests. Marketplace
opening remains absent.

## Rollout (not performed by this change)

1. Install the existing SkillTrack notification/stagnation/push migrations and
   semantic migrations 009 and 010. The canonical base schema is not fully
   checked in; this is not a bootstrap script for an empty Supabase project.
2. Review and apply
   `supabase/migrations/011_stalled_resource_notifications.sql`. It adds
   functions only, preserves types/context constraints/RLS, and raises the
   existing pg_net invocation timeout to 75 seconds. It creates no new cron job,
   secret, table or column.
3. Deploy these two functions from SkillTrack to a test project:

```powershell
npx supabase functions deploy project-notification-generator --remote=YOUR_TEST_PROJECT_REF
npx supabase functions deploy recommend-resources --remote=YOUR_TEST_PROJECT_REF
```

The second deployment picks up the extracted shared matcher and keeps manual and
automatic endpoint behavior identical. **No push-dispatcher redeployment is
required.** The resource-analysis-queue function is unchanged by this feature;
its earlier semantic indexing deployment remains a prerequisite if not yet done.
4. Reuse the existing hourly `project-notification-generator-hourly` job, Vault
URL/secret, notification INSERT webhook and Android device registration.
5. Rebuild the Flutter app for the notification deep-link changes.

## Test-project acceptance steps

- Use an owner with an active project and an incomplete task that crosses the
  actual dynamic inactivity threshold. Use a **new stalled period** without an
  existing generic stalled alert. Do not change production dates/progress to
  test.
- Publish an accessible relevant resource and an unrelated resource; complete
  analysis/indexing so their current embeddings are ready. Enable recommendation
  notifications and Android push permission/preference on the test account.
- Invoke the existing scheduler or wait for it:

```sql
select public.invoke_project_notification_generator();
```

- Read back the single in-app row and inspect the push dispatcher response:

```sql
select id,type,task_id,unique_key,action_data,created_at
from public.notifications
where type in ('STALLED_TASK','LEARNING_RESOURCE_RECOMMENDATION')
order by created_at desc limit 20;

select id,status_code,timed_out,error_msg,content,created
from net._http_response order by created desc limit 10;
```

- Reinvoke: no second row/push for that period. Resume, then arrange a genuinely
  later inactive period: one new alert is allowed.
- Disable only recommendations, hide/deny the relevant resource, or simulate
  matcher failure: the stalled fallback remains available. Disable only stalled
  alerts: a valid recommendation still arrives. Disable push: the in-app row
  still arrives. Disable both categories: neither stalled-event alert arrives.
- On physical Android, test foreground, background and terminated-app delivery,
  duplicate delivery/repeated taps, cold startup, sign-out/account switching,
  notification permission denied, and revoked resource access. Tap either
  surface: confirm the correct task and Learning resources section, then verify
  Back, Resume Task, manual refresh and other task actions.

## Local verification and limits

Tests use fake inference and local PGlite/pgvector with the real checked-in
semantic, notification-table and enqueue SQL on explicit base-schema fixtures.
They do not call Supabase, FCM, Whisper, Gemini or download models. PGlite
serializes requests: task locking and duplicate commits are covered, but actual
multi-session contention, pg_net timing and native gte-small cold starts still
require a Supabase test project.

The generator adapter test is a Node test with module-loader mocks, not a Deno
server test:

```powershell
node --experimental-transform-types --test supabase/functions/project-notification-generator/index.test.ts
```

Run Deno tests with the explicit generator test files, plus recommendation, push
and analysis-queue suites. Do not run that Node adapter under Deno: its Node
loader hooks are what prevent real server/network initialization.

## Files changed for this feature

- `supabase/migrations/011_stalled_resource_notifications.sql`
- `supabase/functions/_shared/recommendations/recommend.ts` (new shared matcher)
- `supabase/functions/_shared/recommendations/indexer.ts`
- `supabase/functions/recommend-resources/handler.ts`, `store.ts`
- `supabase/functions/project-notification-generator/generator.ts`, `index.ts`
- `supabase/functions/project-notification-generator/recommendations.ts` (new
  coordinator)
- `supabase/functions/project-notification-generator/recommendations.test.ts`
- `supabase/functions/project-notification-generator/generator.test.ts`,
  `index.test.ts`
- `supabase/functions/project-notification-generator/README.md`
- `supabase/tests/semantic_recommendations.test.mjs`
- `lib/features/notifications/repositories/notification_repository.dart`
- `lib/features/notifications/repositories/supabase_notification_repository.dart`
- `lib/features/notifications/viewmodels/notification_list_view_model.dart`
- `lib/features/notifications/views/notification_screen.dart`
- `lib/app/router/app_router.dart`, `lib/app/skill_track_app.dart`
- `lib/app/views/main_module_shell.dart`
- `lib/features/kanban/widgets/task_details_sheet.dart`
- `test/features/notifications/fake_notification_repository.dart`
- `test/features/notifications/push_notification_test.dart`

Earlier semantic/manual recommendation changes in the working tree are
preserved.

## Executed local verification

- Dart formatting and `flutter analyze`: passed, no analyzer issues.
- Full Flutter suite: 467 passed, including in-app, background-push and cold-start
  Task Details navigation and repeated-tap protection.
- Deno generator/coordinator, recommendation, push-dispatcher and analysis-queue
  regression suites: 87 passed.
- Node generator adapter suite: 7 passed.
- Local PGlite semantic/notification, stagnation and meaningful-progress database
  suites: 89 passed. These execute the migration and real notification enqueue
  function with schema fixtures, including rollback/retry and recipient RLS.
- Deno entrypoint type checks and production lint passed; `git diff --check`
  found no whitespace errors.

The complete canonical production base schema is not checked in. These local
fixtures cannot establish compatibility with every live constraint or custom RLS
policy. PGlite tests duplicate requests sequentially; true concurrent transactions
need a PostgreSQL/Supabase test instance. Native model inference, Android delivery
and live scheduler/webhook behavior were not executed. No live migration,
deployment, commit or push was performed.
