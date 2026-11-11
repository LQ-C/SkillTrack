# Android push verification

## Observed in this check

CLQ, emulator-5554 (sdk_gphone16k_x86_64), API 37. Google Play services installed.
SkillTrack installed and foreground, stopped=false. POST_NOTIFICATIONS granted.
skilltrack_project_notifications exists with importance 4 (high).
These are environment observations, not proof of a delivered push.
No notification was sent and no backend secret, private payload, or token was read.
No live webhook/FCM response was available. The installed APK was not replaced;
its correspondence to the current source was not established.

A fake-transport regression reproduced loss of old-token retirement after a
successful new-token registration followed by failed unregister. The controller
now retains that cleanup for retry during this account session. Pending retirement
is memory-only; it is not a durable background job. Actual expired tokens are also
handled by the existing dispatcher's invalid-token deactivation.

## Before testing

Use only the designated test account and a dedicated test task. Never send to
another user. Build/install the updated Android app through the usual Flutter
workflow. Sign in, enable push and category preferences in the app, and confirm
Android permission plus the Project notifications channel. No new migration,
secret, or Edge Function deployment is required for this fix.

In the Supabase dashboard verify (without copying credentials):
- notifications INSERT webhook targets project-push-notification-dispatcher.
- x-project-push-secret matches PROJECT_PUSH_WEBHOOK_SECRET.
- FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY belong to the
  same Firebase project as the installed Android client.
- Only the test account's expected active project_push_devices rows are selected.
  Inspect id/platform/is_active/last_seen_at; do not print fcm_token.

Existing setup documentation contains historical migration filenames and stale
pre-semantic statements. Use actual files: project_push_notifications.sql and
011_stalled_resource_notifications.sql for existing prerequisites. Do not rerun
or deploy these solely to test this client cleanup change.

## Dedicated test insert (operator only; not executed)

In a test project SQL Editor, replace TASK_UUID with an owned test task UUID.
Choose one category per run. This deliberately tests delivery/navigation, not
scheduler eligibility or semantic matching. It does not modify the task.

```sql
with target as (
  select u.id user_id, p.id project_id, b.id board_id, t.id task_id
  from auth.users u join public.projects p on p.owner_id=u.id
  join public.kanban_boards b on b.project_id=p.id
  join public.kanban_tasks t on t.board_id=b.id
  where u.email='test@gmail.com' and t.id='TASK_UUID'::uuid
    and p.status='active' and not b.is_archived and not t.is_archived
), scenario as (
  select 'DEADLINE_REMINDER'::text category -- or STALLED_TASK / LEARNING_RESOURCE_RECOMMENDATION
)
insert into public.notifications
  (user_id,type,context_type,title,message,project_id,board_id,task_id,unique_key)
select user_id,category,
  case when category='LEARNING_RESOURCE_RECOMMENDATION' then 'RECOMMENDATION' else 'TASK' end,
  'SkillTrack dedicated push test','Test delivery and task navigation only.',
  project_id,board_id,task_id,'android-test:'||gen_random_uuid()::text
from target cross join scenario
returning id,type,created_at;
```

Zero inserted rows means the task/account eligibility did not match: stop and
correct the test target, do not remove ownership filters. Record the returned
notification UUID and check its matching webhook/dispatcher invocation. A
`sent:1` response means FCM accepted a message; Android display still needs observation.
Never include tokens or credentials in shared logs. Avoid unrestricted logcat or
notification dumps, which can contain other users' private payloads.

## Device matrix (all delivery cases remain unverified)

1. Foreground: keep SkillTrack open. Insert each category separately; confirm one
   Android notification and one in-app row. Repeat delivery for the SAME row via
   the protected dispatcher only if authorized; confirm no duplicate visible item.
2. Background: open another app, insert, tap the notification. Confirm the saved
   task UUID opens once; resource alerts focus Learning resources.
3. Normal termination: remove SkillTrack from Recents (do NOT Force stop), insert,
   tap; wait for initialization/session restoration and confirm one destination.
4. Force stop is a separate control: Android Settings > Force stop is NOT the
   normal-termination scenario. Reopen the app before resuming delivery tests.
5. Repeat with a deleted/inaccessible test task. Expect an unavailable response,
   not another user's task or a crash. Test repeated taps/launch handlers.
6. Deny notifications in Android Settings, resume the app and insert. Confirm no
   Android display, while an eligible in-app notification remains available.
   Restore permission and confirm registration on resume.
7. Disable push_enabled with categories on: no push. With push on, disable each
   category independently and test that category. Inserting a test row directly
   bypasses generator preferences; dispatcher preferences must still block push.
8. Sign out; verify cleanup/invalidation. Sign in as a second authorized TEST
   account only if one is available; confirm old-account notifications do not
   display or navigate. Never borrow another real user's account.
9. Token refresh: observe registration and retirement through sanitized metadata.
   Do not manually corrupt real tokens. Invalid-token deactivation is covered by
   fake backend tests; use a disposable test installation for device validation.

Record scenario, notification UUID, dispatcher counts, Android display count,
opened task and section, and timestamp. Until these observations exist, mark the
case unverified, even when widget or dispatcher tests pass.
