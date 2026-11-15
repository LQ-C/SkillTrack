# FYP-SkillTrack

SkillTrack is a Flutter learning and project-management app combining projects, Kanban boards, milestones, timers, AI task generation, resource recommendations, and a peer-to-peer mentor marketplace. Students can purchase mentor materials and book sessions; mentors can publish resources and manage their teaching profile. Android also supports push notifications.

This guide describes the **integrated application in this repository**. Commands use Windows PowerShell and run from the repository root unless a different working directory is shown. Replace all `YOUR_...` placeholders before using them.

## 1. Prerequisites

| Component | Needed for |
| --- | --- |
| Git | Cloning the source |
| Flutter stable with Dart compatible with `^3.11.4` | Application build and Flutter tests; use the committed `pubspec.lock` |
| Android Studio, Android SDK and a compatible JDK | Android builds; the project uses Java 17 compilation settings |
| Android device/emulator with Google Play services | Android app and FCM push checks |
| Supabase project and administrator access | Authentication, PostgreSQL, private Storage, Realtime and Edge Functions |
| Node.js 24+ and npm | Supabase CLI commands and isolated backend tests |
| Python 3.13 | Local extraction worker; a dedicated virtual environment is recommended |
| FFmpeg, whisper.cpp and a Whisper model | Uploaded-video audio transcription |
| PyMuPDF and Tesseract English language data | PDF extraction, including OCR |
| Firebase project | Android Firebase initialization and optional push delivery |
| Gemini API key | AI project-task generation and resource/image analysis |

Python and native extraction tools are optional if you only need to run the Flutter UI against an already configured backend. Docker is needed for a local Supabase stack, but is not needed to run Flutter or deploy functions with `--use-api`.

Install Flutter and Android tooling, then check:

```powershell
flutter --version
dart --version
flutter doctor -v
flutter doctor --android-licenses
flutter devices
node --version
py -3.13 --version
```

Resolve Android toolchain errors reported by `flutter doctor` before building. iOS requires macOS/Xcode and separate platform configuration; this guide's device instructions target Android.

## 2. Clone and install Flutter packages

```powershell
git clone https://github.com/LQ-C/FYP-SkillTrack.git
Set-Location FYP-SkillTrack
flutter pub get
```

For the existing local checkout, use this instead of cloning again:

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack - final'
flutter pub get
```

## 3. Configure the Flutter app

### Supabase client configuration

Create the ignored local configuration only if it does not already exist:

```powershell
if (-not (Test-Path -LiteralPath 'config/supabase.json')) {
    Copy-Item 'config/supabase.example.json' 'config/supabase.json'
}
```

Edit `config/supabase.json`:

```json
{
  "SUPABASE_URL": "https://YOUR_PROJECT_REF.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "YOUR_SUPABASE_PUBLISHABLE_KEY"
}
```

Use the URL and publishable/client key from the **same** Supabase project. A legacy anon key can also be used as the client key. Never put a service-role key, Gemini key, Firebase private key or Stripe secret in Flutter configuration: Flutter assets and Dart defines are distributed with the app.

Alternatively, provide build-time settings:

```powershell
flutter run -d YOUR_DEVICE_ID `
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_SUPABASE_PUBLISHABLE_KEY
```

`lib/main.dart` also accepts the legacy `SUPABASE_ANON_KEY` Dart define. Dart defines take precedence over the corresponding JSON values. Stop and restart the app after changing build configuration.

### Android Firebase configuration

The Android application ID is `com.example.skilltrack`. This repository includes Firebase client configuration in `android/app/google-services.json` and `lib/core/config/firebase_options.dart`.

- When using the existing project, obtain confirmation that these files match the intended Firebase project.
- For your own Firebase project, register an Android app with the same application ID, replace `android/app/google-services.json`, and regenerate the options file at `lib/core/config/firebase_options.dart` using FlutterFire CLI. Keep both files consistent.
- For a physical device or emulator, make sure Google Play services are available.

Android initializes Firebase during startup, even before the user opts into push. Push delivery additionally requires the server setup in section 7. Client Firebase configuration is different from a private Firebase service-account key.

## 4. Prepare Supabase

### Existing integrated backend

If the project's integrated backend is already configured, **do not bootstrap or replay migrations**. Obtain its project URL/client key, confirm the deployed schema/functions and bucket policies, then continue to sections 5–8 for any missing services.

Review unapplied changes against the actual database. The repository mixes a schema snapshot, numbered incremental changes and historical standalone scripts; a blind `supabase db push` or `db reset` is not the setup procedure for this checkout.

### Fresh development/test backend

Use a new Supabase project with no existing application tables. The schema bootstrap explicitly refuses a database containing `profiles`, `projects` or `learning_resources`.

In Supabase SQL Editor, review and execute these **whole files**, in this order:

| Order | File | Purpose |
| --- | --- | --- |
| 1 | `supabase/marketplace_history/combined_schema_marketplace_profiles_v2.sql` | Integrated baseline: authentication profiles, marketplace, projects/tasks, notifications, extraction and indexing definitions, RLS and RPCs |
| 2 | `supabase/setup/marketplace_private_buckets.sql` | Creates missing application buckets and checks existing buckets are private |
| 3 | `supabase/migrations/017_marketplace_storage_compatibility.sql` | Reconciles marketplace file references with the integrated processing pipeline |
| 4 | `supabase/migrations/018_split_mentor_resource_buckets.sql` | Split image/PDF and MP4 uploads, preserving legacy locations and authorised reads |
| 5 | `supabase/migrations/019_resource_storage_policy_helper_permission.sql` | Grants the authenticated policy helper permission required by file access |
| 6 | `supabase/migrations/020_mentor_resource_previews.sql` | Safe mentor-card preview metadata, separate from protected content |
| 7 | `supabase/migrations/021_expand_resource_categories.sql` | Adds software categories while preserving existing accepted values |

The combined baseline already represents the older integration stages, including extraction and task-list replacement. Do not follow it by replaying migrations `001`–`016`, the dated marketplace history, or all standalone project/task/notification scripts. Those files document prior stages and can overlap or supersede each other.

The baseline is **schema only**: it does not import Auth users, resource rows, Storage objects, bucket rows, secrets, Edge Functions or cron jobs. It requires Supabase's managed roles/schemas and extensions, including Vault, pg_cron, pg_net and pgvector; it is not a generic PostgreSQL restore script. Review any prerequisite/permission error rather than removing guards, RLS or constraints. A complete fresh hosted deployment has not been revalidated as part of writing this README.

Do not run `supabase/marketplace_history/local_test_platform.sql` on hosted Supabase; it is an isolated test fixture. For an existing database requiring attachment normalization, inspect `supabase/setup/normalize_existing_attachments.sql` separately, with a backup and reviewed mapping. A new empty database does not need legacy backfills.

### Authentication and roles

1. Enable Email authentication and keep email verification enabled.
2. Under Authentication URL configuration, allow the Android redirect `com.skilltrack.app://login-callback/` for verification/password-reset callbacks.
3. If testing web, add the exact development web origin used by the app. A fixed development port avoids changing redirects on every run.
4. Sign up through the app so `full_name`, `date_of_birth` and `role` metadata are supplied to the profile trigger. Configure SMTP if the project's email delivery limits prevent reliable verification.
5. Verify the email, then sign in.

The integrated baseline includes `on_open_mentor_role`, `require_qualification` and `tutor_publisher_sync`. Saving Student → Mentor enables the mentor profile and publisher through the existing open-mentor rules. Saving Mentor → Student removes publishing capability while retaining mentor data. There is no new qualification-approval step. Switching roles does not purchase paid materials or session credits.

### Private Storage

| Bucket | Public | New upload types | Configured maximum |
| --- | --- | --- | --- |
| `mentor-reading-files` | No | PDF, PNG, JPG/JPEG | 10 MiB |
| `mentor-video-files` | No | MP4 | 50 MiB |
| `mentor-qualifications` | No | Existing qualification-document support | 10 MiB |
| `task-attachments` | No | Existing task attachment workflow | 10 MiB |

Bucket existence is not enough: INSERT and SELECT policies must also be installed. Both resource buckets require private access policies that retain ownership, publication, moderation and paid entitlements. Review settings/policies with `supabase/setup/audit_mentor_resource_buckets.sql`.

Older MP4s can remain in `mentor-reading-files`; older `marketplace-videos`/`marketplace-documents` references are also supported by the processing code. Do not move/copy/delete live objects to satisfy setup. Copying a file can change its Storage identity/version and require re-extraction/reindexing. YouTube links stay external references and are not uploaded into Storage. Signed URLs have a limited lifetime; revoking access does not instantly invalidate an already-issued URL.

## 5. Configure and deploy Edge Functions

These commands are **operator deployment steps**, not required merely to clone/build the app. Use a development/test project first. Examples pin the CLI version whose `--remote` and `--use-api` flags were checked for this repository:

```powershell
npx --yes supabase@3.1.0 login
```

Create a private environment file outside the repository, for example `C:\secure\skilltrack-edge.env`:

```dotenv
GEMINI_API_KEY=YOUR_GEMINI_API_KEY
RESOURCE_ANALYSIS_CRON_SECRET=YOUR_RANDOM_SECRET_AT_LEAST_32_CHARACTERS
PROJECT_NOTIFICATION_CRON_SECRET=YOUR_SEPARATE_LONG_RANDOM_SECRET
RESOURCE_VIDEO_BUCKET=mentor-video-files
RESOURCE_PDF_BUCKET=mentor-reading-files
RESOURCE_IMAGE_BUCKET=mentor-reading-files
```

Hosted Supabase functions receive their Supabase URL, anon/client key and service-role environment from the platform. Do not copy backend credentials into the Flutter asset directory. Model overrides `GEMINI_RESOURCE_TAG_MODEL` and `GEMINI_RESOURCE_IMAGE_MODEL` are optional; use a model available to your Gemini project. Semantic embeddings use the existing native `gte-small` implementation rather than a new client API key.

```powershell
npx --yes supabase@3.1.0 secrets set --remote=YOUR_PROJECT_REF `
  --env-file 'C:\secure\skilltrack-edge.env'
```

Deploy the functions used by the current integrated flows:

```powershell
npx --yes supabase@3.1.0 functions deploy generate-project-tasks --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
npx --yes supabase@3.1.0 functions deploy recommend-resources --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
npx --yes supabase@3.1.0 functions deploy resource-analysis-queue --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
npx --yes supabase@3.1.0 functions deploy project-notification-generator --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
npx --yes supabase@3.1.0 functions deploy project-push-notification-dispatcher --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
npx --yes supabase@3.1.0 functions deploy delete-account --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
```

`--no-verify-jwt` disables the gateway check, not application authorization. Task generation/recommendations validate the user in their middleware; account deletion validates the caller/password; schedulers and push use their dedicated shared-secret headers. Do not remove those checks. `supabase/config.toml` also records gateway settings for the scheduler, recommendation and push endpoints.

`register-mentor` and `mentor-payments` are retained implementations but are not prerequisites for the current app signup/open-role and demo-checkout flows. Do not enable a different historical workflow as part of basic setup.

## 6. Activate scheduled analysis and notifications

After deploying/configuring functions, use Supabase Vault to store:

| Vault name | Value |
| --- | --- |
| `resource_analysis_url` | `https://YOUR_PROJECT_REF.supabase.co` (base URL) |
| `resource_analysis_cron_secret` | Same value as Edge `RESOURCE_ANALYSIS_CRON_SECRET` |
| `project_notification_url` | Same project base URL |
| `project_notification_cron_secret` | Same value as Edge `PROJECT_NOTIFICATION_CRON_SECRET` |

Use Vault's Dashboard interface to avoid putting secret values into committed SQL. Update existing named secrets instead of creating duplicate names.

The snapshot includes invocation functions but does not create the cron jobs. For a **fresh setup**, schedule:

```sql
select cron.schedule(
  'resource-analysis-queue-every-minute', '* * * * *',
  $$select public.invoke_resource_analysis_queue();$$
);
select cron.schedule(
  'project-notification-generator-hourly', '0 * * * *',
  $$select public.invoke_project_notification_generator();$$
);
```

For an existing project, inspect the current schedules before adding or changing anything:

```sql
select jobid, jobname, schedule, active from cron.job;
select jobid, status, start_time, end_time
from cron.job_run_details order by start_time desc limit 20;
```

The analysis function drains analysis/image/embedding work. Local extraction must first produce video/PDF text for those resource types. The hourly notification function handles deadlines, stagnation and recommendation alerts. Check function logs, Gemini quota and cron results before relying on unattended processing. Scheduler invocations can write jobs/results; they are not read-only health checks.

## 7. Configure Android push delivery

For push, add these server-only values to the private Edge environment file and upload it again with the `secrets set` command above:

```dotenv
FIREBASE_PROJECT_ID=YOUR_FIREBASE_PROJECT_ID
FIREBASE_CLIENT_EMAIL=YOUR_FIREBASE_SERVICE_ACCOUNT_EMAIL
FIREBASE_PRIVATE_KEY="YOUR_FIREBASE_SERVICE_ACCOUNT_PEM_PRIVATE_KEY"
PROJECT_PUSH_WEBHOOK_SECRET=YOUR_SEPARATE_RANDOM_SECRET_AT_LEAST_32_CHARACTERS
```

Use a Firebase service account permitted to send FCM messages. The dispatcher accepts literal `\n` sequences in the PEM value. Keep the key private and use the same Firebase project as the Android configuration.

In Supabase Database Webhooks, configure:

| Setting | Value |
| --- | --- |
| Table | `public.notifications` |
| Event | INSERT only |
| Method | POST |
| URL | `https://YOUR_PROJECT_REF.supabase.co/functions/v1/project-push-notification-dispatcher` |
| Header | `x-project-push-secret` |
| Header value | Same value as `PROJECT_PUSH_WEBHOOK_SECRET` |

Verify `public.notifications` is enabled in the `supabase_realtime` publication for inbox/badge updates; the combined snapshot includes this publication membership. Do not add duplicate membership if it is already enabled.

After login, the app's Android onboarding offers notification consent. The account push preference and installation permission must both allow push; Not Now does not silently enable account preferences. The manual entry point is **Profile → Notification Settings**. In-app notifications and push are separate delivery paths. Test foreground, background, terminated-app taps, Settings return and account switching on a suitable Android device.

## 8. Set up the local extraction worker

The worker runs on your PC, makes outbound Supabase requests, and needs no public HTTP endpoint. The PC must remain on for video/PDF extraction. Image analysis and semantic indexing run in Edge Functions; do not look for a second local image worker.

### Install Python dependencies

From the repository root:

```powershell
Set-Location workers/content_analysis
py -3.13 -m venv .venv
& '.\.venv\Scripts\python.exe' -m pip install -r '.\speech-to-text\requirements.txt'
Set-Location speech-to-text
if (-not (Test-Path -LiteralPath '.env')) {
    Copy-Item '.env.example' '.env'
}
```

### Install native tools/models

Download a compatible whisper.cpp CLI build and multilingual `ggml-small.bin` model from the [whisper.cpp project](https://github.com/ggml-org/whisper.cpp), and install standalone [FFmpeg](https://ffmpeg.org/download.html). A CPU build can be used without an NVIDIA GPU. Keep any DLLs required by the chosen whisper.cpp build alongside its executable.

Expected layout relative to `workers/content_analysis`:

```text
.venv/
Tesseract-OCR/tessdata/eng.traineddata
speech-to-text/
  .env
  tools/
    ffmpeg.exe
    ggml-small.bin
    whisper-cuda/Release/whisper-cli.exe
    whisper-cuda/Release/<required DLLs>
```

For PDF OCR, supply Tesseract's `eng.traineddata`; PyMuPDF is installed by `requirements.txt`. The chosen CLI path can differ from this example if `.env` points to the actual executable. Native binaries, language data, models, `.venv` and extraction output are ignored by Git and do not come with a clone. Do not assume another PC has this project's old junction targets or copy an existing virtual environment from another directory.

Edit `speech-to-text/.env` while your working directory is `speech-to-text`:

```dotenv
SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
SUPABASE_SERVICE_ROLE_KEY=YOUR_BACKEND_ONLY_SERVICE_ROLE_KEY
VIDEO_BUCKET=mentor-video-files
PDF_BUCKET=mentor-reading-files
WHISPER_CPP_EXE=tools/whisper-cuda/Release/whisper-cli.exe
WHISPER_CPP_MODEL=tools/ggml-small.bin
FFMPEG_EXE=tools/ffmpeg.exe
WHISPER_CPP_LANGUAGE=en
WHISPER_CPP_USE_GPU=true
TESSDATA_PREFIX=C:/YOUR_CLONE/workers/content_analysis/Tesseract-OCR/tessdata
POLL_SECONDS=30
LEASE_SECONDS=900
RENEW_SECONDS=60
DISCOVERY_BATCH_SIZE=25
TRANSCRIBE_TIMEOUT_SECONDS=7200
PDF_EXTRACT_TIMEOUT_SECONDS=600
MAX_VIDEO_MB=1024
```

Set `WHISPER_CPP_USE_GPU=false` for CPU inference and use a compatible CPU CLI. `TESSDATA_PREFIX` must point to the directory containing `eng.traineddata`. Absolute executable/model paths are also supported and help avoid working-directory mistakes. `MAX_VIDEO_MB` is a worker download ceiling shared with extraction inputs, not a change to the app's 50 MiB MP4 upload limit.

The integrated discovery supports the new video bucket and legacy video locations, including MP4s in `mentor-reading-files`. PDF discovery supports `mentor-reading-files` and the configured legacy PDF bucket. It validates stored references and source identity/version, rather than assigning every MP4 to a new bucket by extension.

### Verify offline, then start intentionally

Run from `workers/content_analysis/speech-to-text`:

```powershell
& '..\.venv\Scripts\python.exe' -m unittest discover -s tests -v
& '..\.venv\Scripts\python.exe' demo_simulated.py
& '..\.venv\Scripts\python.exe' test_local.py 'C:\path\to\local-fixture.mp4'
```

The first two use fakes. `test_local.py` runs the real native tools on the chosen local file without writing to Supabase. To check a local PDF, run from `workers/content_analysis`:

```powershell
& '.\.venv\Scripts\python.exe' pdf_extraction.py 'C:\path\to\local-fixture.pdf'
```

Once the backend and private worker configuration are ready, deliberately start queue processing from `speech-to-text`:

```powershell
& '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker
```

Stop with Ctrl+C. The worker uses leases, retries and stale-source checks; do not manually change queue identities or bypass those checks.

**Queue safety:** normal worker execution writes to the configured backend. `--once` also claims and processes a real eligible job; it is not a dry run. `--draft-resource-id` limits discovery, not the global claim queue. Use offline fixtures for verification and an isolated test project for end-to-end queue checks. Never run either mode against a live queue merely to check installation.

## 9. Run and build the app

Return to the repository root, then:

```powershell
flutter devices
flutter run -d YOUR_DEVICE_ID
```

If you configured Dart defines instead of the JSON file, pass the same defines on run/build commands. To create a debug APK:

```powershell
flutter build apk --debug
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`.

For release distribution, configure your private keystore through `android/key.properties` (`storePassword`, `keyPassword`, `keyAlias`, `storeFile`) before `flutter build apk --release` or `flutter build appbundle --release`. Without private release signing configuration, the Gradle setup produces an unsigned release artifact. Never commit signing keys/passwords. A hot reload cannot install missing native plugin code; stop and rebuild/reinstall when plugins or Firebase/native configuration change.

### First-use checks

1. Sign up in the app, verify email and log in.
2. Create a project, open its Kanban board and add tasks/milestones.
3. Select Mentor in Profile and tap **Save profile**; check Explore management and Library's Add resource action without logging out.
4. Set up the mentor's profile, listing, availability and materials price as needed. Use separate verified student/mentor test accounts.
5. Publish isolated PDF/image/MP4 resources and check their bucket/policies. Do not make a bucket public to fix an access error.
6. As a student, check locked material previews before purchase and authorised details/playback afterward.
7. Check recommendations after extraction, analysis and indexing complete, then verify task-specific bookmarks separately from marketplace bookmarks.

### Payment mode

The current Flutter mentor/session checkout uses the existing **demo-payment RPC flow**. It records simulated outcomes; it does not charge a real card. Materials access and session credits/pricing are separate according to the current purchase kind. Role changes do not grant access.

The retained `supabase/functions/mentor-payments` implementation is a separate Stripe **test-only** flow with `STRIPE_TEST_SECRET_KEY` and `STRIPE_TEST_WEBHOOK_SECRET`. Its historical README links to a setup file absent from this checkout, and the integrated schema restricts orders to the demo provider. Deploying that function alone does not switch the current UI/schema to Stripe. Treat activating a different payment flow as a separately reviewed integration; no live-payment setup is provided by this README.

## 10. Tests and validation

Flutter, from the repository root:

```powershell
flutter analyze
flutter test
```

Focused media tests:

```powershell
flutter test test/marketplace/resource_image_preview_test.dart test/marketplace/fullscreen_video_controls_test.dart test/marketplace/uploaded_video_test.dart test/marketplace/resource_bucket_split_test.dart
```

Backend fixtures, from the repository root:

```powershell
Push-Location supabase/tests
npm ci
npm test
Pop-Location
```

These Node/PGlite fixtures use isolated in-memory database data; they are different from applying SQL to hosted Supabase. Run worker offline/native commands from section 8 separately. A successful Flutter build does not prove deployed RLS, email delivery, Gemini quota, scheduled execution, real private-file playback, or device push delivery.

Latest local media validation: Flutter analysis and Android debug build passed; the full Flutter suite had **698 passing tests and 4 existing failing Mentor-card inline-preview tests** in `test/marketplace/mentor_video_access_test.dart`. Those tests expect preview UI absent from the current Mentor page. This is a known test/UI mismatch, not a requirement to disable paid access. Media smoke checks used local fixtures on an Android emulator; physical-device and hosted-service acceptance checks remain separate.

## 11. Troubleshooting

| Symptom | Check |
| --- | --- |
| “Connect your account service” | Missing/empty `config/supabase.json`, wrong key names, or absent Dart defines. Rebuild/restart after configuring. |
| “Database error creating new user” | Inspect Auth/Postgres logs and `handle_new_account`/profile triggers; app signup supplies required name, birth-date and role metadata. Manual Dashboard creation must supply the expected metadata too. |
| Saved Mentor role cannot publish | Verify the confirmed profile role, verified email, open-mentor triggers and `content_publishers`; inspect retained-tab refresh errors. Do not introduce qualification approval as a workaround. |
| Upload/signing permission error | Check both bucket privacy settings, Storage policies, ownership/path references and migration 019's helper grant. |
| Private image/video unavailable | Recheck current entitlement/publication/moderation, file existence and stored bucket/path. Retry obtains a newly authorised URL. |
| Player reports a missing native plugin | Stop the app and rebuild/reinstall; hot reload is insufficient. Also verify the MP4 encoding is supported on the target Android device. |
| Analysis/recommendations stay empty | Check extraction queue, current file identity/version, worker process, Edge logs, cron/Vault names, Gemini quota and embedding readiness. No matching accessible resource is also a valid result. |
| Worker reports a configuration/tool error | Check the current directory, private `.env`, venv dependencies, CLI/DLL/model paths, FFmpeg and `eng.traineddata`. |
| Inbox updates but push does not | Check account preference, Android installation permission, device registration, Firebase project/service-account credentials and the INSERT webhook secret. |
| Old setup link/path does not exist | Some component READMEs predate integration and reference removed `docs/` files, original folders or old migration filenames. Use this root guide for current paths and setup order. |

## 12. Project layout and architecture

```text
lib/
  app/                         Theme, router, application shells and shared widgets
  core/                        Shared configuration, constants, validation and utilities
  features/
    authentication/            Signup, login, verification and account service
    profile/                   Profile form and confirmed account-role changes
    dashboard/                 Home sections and project overview
    projects/                  Project CRUD and staged progress loading
    kanban/                    Boards, tasks, milestones, timers and activity
    ai_task_generation/        Generated task previews and server-backed persistence
    educational_content/       Library, resource editor/details and private media widgets
    tutor_management/          Mentor discovery, materials access, demo checkout and sessions
    learning_integration/      Task recommendations and task-specific saved resources
    notifications/             Inbox, preferences, permission onboarding and push
supabase/
  marketplace_history/         Guarded integrated schema snapshot and historical references
  migrations/                  Incremental SQL and historical feature migrations
  setup/                       Private bucket setup, audits and attachment normalization
  functions/                   Edge Functions and shared backend code
  tests/                       Isolated backend/SQL fixtures
workers/content_analysis/      Local video/PDF extraction and native-tool configuration
test/                          Flutter unit, widget, repository and navigation tests
```

The app follows MVVM: views/widgets present UI; ViewModels coordinate state and asynchronous requests; repositories/services perform authorised data access. SQL RLS and RPC checks remain the authority for ownership, publication, moderation, paid resources and bookings. Keep marketplace bookmarks, task-specific bookmarks and task attachments distinct.

## Configuration hygiene

Real `config/supabase.json`, worker `.env`, native binaries/models, virtual environments and build output are ignored. Keep server environment files and service-account material outside the repository. Do not paste secrets or signed URLs into screenshots/logs. Before committing, review `git status --short` and the staged diff. No migration, deployment, queue job, real payment or live-data change is performed merely by following the source-inspection/testing portions of this guide; the operator actions above must be executed deliberately against the chosen environment.
