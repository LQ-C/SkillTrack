> Current split-bucket update: [RESOURCE_BUCKET_SPLIT.md](RESOURCE_BUCKET_SPLIT.md). New MP4 uploads now use mentor-video-files; legacy reading-bucket videos remain supported.

# Marketplace integration handoff

Worktree: `C:\Users\PC\Documents\FYP\SkillTrack - final`.
Branch: `codex/marketplace-integration`. No commits, pushes or deployments made.
Source revisions: SkillTrack `29886e435e01690f82637addf61b3e493aed7967`; teammate `c65475b88e2a929a20935f46af140b3d45b3690f`.
The initial `main` checkout was clean. No AGENTS.md instructions were found in
this checkout or its inspected parent folders. The teammate checkout is separate
at `C:\Users\PC\Documents\ChatGPT\FYP\staging\marketplace-reference`.

## Implemented locally

- Imported implemented authentication, recovery, profile, mentor directory/details,
  resource library/editor/details, YouTube player, file opening, availability,
  booking, session management, feedback, and demo checkout features. The teammate
  page structures and form order remain; fixed accents now use SkillTrack purple.
- One main(), Supabase client, authentication session, MaterialApp, theme and
  shared router. Marketplace dependencies are injected from main(). Existing
  project/task repositories already use auth.users UUIDs; they share that client.
- Home | Explore | Library | Project | Profile use one persistent navigation bar.
  Tabs load lazily in an IndexedStack and preserve widget/scroll/form state.
  Android Back returns from another tab to Home. Account changes discard private
  tab state, pop private routes, and reset notification subscriptions/badges.
- Notification bells on all main tabs retain exact unread counts and existing
  realtime, inbox, preferences, Android push and initial-message transport.
  Project notifications open their project board, task notifications open task
  details, and resource recommendation notifications with resource_id open the
  actual resource details. Older recommendation alerts retain the task-resources
  destination. Repeated bell/tab/resource callbacks are guarded.
- Recommendation cards and task-specific saved resources open the same resource
  details as Library. Task bookmarks and marketplace content_bookmarks remain
  separate. Existing recommendation sets, refresh, indexing, task layouts,
  generation/revision/replacement, tracking and monitoring stay in their features.
- Uploaded MP4/PDF/PNG/JPEG files remain in private mentor-reading-files. New
  uploads retain attachment_path and also save a stable authenticated Storage
  reference for SkillTrack analysis. Short-lived signed URLs open files only
  through Storage authorization. Legacy marketplace-videos/documents references
  are supported, with host/bucket/path checks. YouTube retains inline playback;
  MP4 uses the teammate's external-player workflow. YouTube transcription is not
  provided by the existing file-transcription worker.
- Account deletion retains password reauthentication and now cleans owned
  marketplace/task file prefixes, with isolated cleanup tests.

## Conflict decisions

Use the canonical Marketplace profiles contract (id, full_name, date_of_birth,
student/mentor role, bio, timestamps) and Marketplace publication/moderation/paid
resource access policies. Do not overlay older broad resource/profile policies.
Project owner_id remains the same auth.users/profile UUID; no IDs are remapped.
The latest marketplace library entitlement is a paid materials/legacy order,
not the superseded manual mentor grant. Session payments remain separate.
Current checkout calls simulation RPCs; it does not use Stripe or charge money.
The imported mentor-payments and register-mentor functions are legacy reference
capabilities and are not needed for the current demo/registration workflow.

The combined schema snapshot was already available locally and was inspected,
not freshly exported from a hosted project. Its fresh-database guard is retained.
Historical SkillTrack migrations are unchanged. Historical teammate migrations
are kept under supabase/marketplace_history and are not automatically applied.
Only migration 017 changes the active compatibility contract: attachment URL
constraint and the verified PDF extraction bucket allowlist. It keeps ownership,
moderation, Storage object identity/version and extraction idempotency checks.
It does not change SELECT policies or make a bucket public.

file_picker moved from 11 to 13 to match teammate upload code. The existing task
attachment picker was adapted to readAsByteStream(), retaining its bounded read.
Firebase package/application configuration and push channels are preserved;
Android adds only the existing account callback scheme intent filter.

## Backend and configuration steps (prepared; not executed)

1. Choose ONE integration Supabase project. For a fresh test project, review and
   run `supabase/marketplace_history/combined_schema_marketplace_profiles_v2.sql`.
   It installs the combined application schema only. Do not run it on a populated
   source project, and do not replay all historical migrations afterward.
2. For an existing populated target, inspect its actual tables/functions/policies
   first and reconcile it to the same canonical contract. Existing optional/null
   SkillTrack birth dates cannot satisfy Marketplace's required date_of_birth
   automatically. Retain real user UUIDs and collect missing profile data; never
   invent dates or merge identities by email. An actual populated-target data
   migration remains blocked on that target's schema/data mapping.
3. After the canonical schema (including SkillTrack 001-016 equivalents), apply
   `supabase/migrations/017_marketplace_storage_compatibility.sql` once.
4. Review/run `supabase/setup/marketplace_private_buckets.sql` for required private
   bucket definitions. It does not overwrite existing settings; verify existing
   MIME/size limits match. The combined schema supplies their Storage policies.
   Legacy file buckets/bytes are not copied; separately migrate them if needed,
   retaining private authorization. Never expose paid files via a public bucket.
5. If existing attached resources have empty external_url, edit the guarded URL
   placeholder in `supabase/setup/normalize_existing_attachments.sql`, review the
   selected rows and apply it on the integration target. New uploads need no
   backfill. The normal analysis queues then discover current file versions.
6. Copy config/supabase.example.json to ignored config/supabase.json and set only
   SUPABASE_URL and the target's publishable key. Alternatively use Flutter Dart
   defines SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY (SUPABASE_ANON_KEY alias is
   supported). Never put service-role keys in Flutter. Without configuration the
   app displays setup. No live keys were supplied or copied for this integration.
7. In target Auth settings enable the intended email confirmation policy and add
   `com.skilltrack.app://login-callback/` to allowed redirects. For web also add
   its real origin. Verify actual email verification and password-recovery links.
8. Deploy only when explicitly authorized, using target-specific CLI configuration:

   ```powershell
   npx --yes supabase@3.1.0 functions deploy delete-account --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
   npx --yes supabase@3.1.0 functions deploy generate-project-tasks --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
   npx --yes supabase@3.1.0 functions deploy resource-analysis-queue --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
   npx --yes supabase@3.1.0 functions deploy recommend-resources --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
   npx --yes supabase@3.1.0 functions deploy project-notification-generator --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
   npx --yes supabase@3.1.0 functions deploy project-push-notification-dispatcher --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
   ```

   These handlers retain their own user/shared-secret checks. Configure their
   secrets through the target secret store: Gemini key/model settings, analysis
   and notification cron secrets, and target Firebase push credentials. Follow
   each existing feature README for its exact environment names. Do not deploy
   legacy Stripe functions or configure a payment provider for the demo flow.
   Required secret names are `GEMINI_API_KEY`, `RESOURCE_ANALYSIS_CRON_SECRET`,
   `PROJECT_NOTIFICATION_CRON_SECRET`, `PROJECT_PUSH_WEBHOOK_SECRET` (at least
   32 characters), `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, and
   `FIREBASE_PRIVATE_KEY`. Supabase supplies server-side SUPABASE_URL,
   SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY. Optional analysis model names
   are GEMINI_RESOURCE_TAG_MODEL and GEMINI_RESOURCE_IMAGE_MODEL. Recommendation
   tuning variables RECOMMENDATION_MIN_SIMILARITY, RECOMMENDATION_MIN_SCORE,
   RECOMMENDATION_SEMANTIC_WEIGHT and RECOMMENDATION_KEYWORD_WEIGHT retain their
   existing defaults. Keep server secret values out of Flutter/build defines.

9. Keep RESOURCE_VIDEO_BUCKET=marketplace-videos, RESOURCE_PDF_BUCKET and
   RESOURCE_IMAGE_BUCKET=marketplace-documents when those legacy buckets exist.
   Mentor attachments are selected per resource, and the image drain also polls
   mentor-reading-files. The local worker discovers both the configured legacy
   buckets and the verified mentor bucket. Configure its ignored environment,
   service-role key, ffmpeg and whisper.cpp paths; use the existing worker README.
10. Recreate target cron jobs/Vault secrets and configure the push webhook to the
    target dispatcher. The combined bootstrap intentionally leaves old-project
    push dispatch disabled/deferred. Use this app's Firebase Android project and
    its matching FCM service credentials. Do not reuse source webhook secrets.

## Reproduce local checks

From the repository root:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
npm --prefix supabase/tests ci --ignore-scripts
npm --prefix supabase/tests test
npx --yes deno@2.9.6 test --no-lock supabase/functions/resource-analysis-queue supabase/functions/recommend-resources supabase/functions/_shared/recommendations supabase/functions/project-notification-generator/recommendations.test.ts supabase/functions/project-push-notification-dispatcher supabase/functions/delete-account/storage_cleanup.test.ts
npx --yes deno@2.9.6 check supabase/functions/delete-account/index.ts supabase/functions/mentor-payments/index.ts supabase/functions/register-mentor/index.ts supabase/functions/resource-analysis-queue/index.ts
python -m unittest discover -s workers/content_analysis/speech-to-text/tests -t workers/content_analysis/speech-to-text
```

The SQL checks use isolated, in-memory PGlite fixtures. They do not connect to
Supabase. The worker's optional PDF-native dependency check may be skipped when
its local dependency is absent. See VALIDATION.md for final measured results.

## Limits requiring target/device verification

No hosted schema, users, Storage, function, cron, Firebase or payment state was
modified. There is no configured integration Supabase session in this checkout.
Email delivery, hosted RLS against real users, actual media transcription/OCR,
external player availability, real-time reconnection and FCM cold-start delivery
must be verified on the chosen test target and a physical/emulated Android device.
The full combined-schema restore/rollback fixture was not rerun because the
local Docker Linux engine was unavailable. Its prior validation file is reference
only. The new compatibility migration is tested with isolated PGlite fixtures.

Pre-existing test issue: two push widget tests created their serial queue in
setUp outside Flutter's fake-async zone and could assert before initialization.
The failure reproduced with the original app lifecycle. Their fixtures now create
the controller inside the widget-test zone, matching existing recommendation
push tests. No production transport workaround was added for that test issue.
