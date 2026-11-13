# Android notification permission onboarding

Implemented locally on the existing `main` branch. Prior uncommitted integration
work was preserved. No database migration, backend deployment, account creation,
commit or push was made. No live notification preference/token data was changed.

## Consent and prompt rules

- The host is inside the authenticated AccountGate and around the existing main
  shell. It checks after the first rendered main frame, including a cold-start
  signed-in session. If a notification route is in front of the main page, the
  existing route observer defers the check until the main page becomes visible.
  Login, recovery and the rest of the application remain usable on failure.
- A permission check never launches Android's prompt. Enable Notifications is
  required first. Not Now and previously presented onboarding are remembered
  once per installation, across logins, app restarts, tabs and resumes.
- Already-granted permission plus an enabled account preference reuses the
  existing registration/reconciliation flow without any permission prompt.
  Already-granted permission plus a disabled preference requires explicit consent.
- Android 13+ retry eligibility combines Android's current rationale signal with
  a persisted request count. Requests are bounded (initial request plus at most
  one explicit retry when Android offers a rationale). After a denial/dismissal
  with no retry signal, use Open Settings. A Firebase denied value alone is never
  interpreted as never requested. Android before 13 has no runtime notification
  dialog: if notifications are disabled, the user is directed to Settings.
  API 24–25 uses app-details Settings; API 26+ uses app-notification Settings.
- An installation upgraded from older code has no complete request history; its
  first explicit request may be declined immediately by Android. It then moves
  to Settings guidance instead of repeatedly requesting. No privileged permission
  inspection API or unreliable inference from Firebase status was added.
- The tiny local record lives in Android noBackupFilesDir via AtomicFile, so it
  is not restored onto another installation through normal Android backup.
  No new package dependency was added. Other platforms skip automatic onboarding.
- Enable consent registers the device before persisting push_enabled=true.
  Failure leaves the previous account preference unchanged and attempts device
  rollback/cleanup. Not Now does not save account preferences. Latest category
  switches are reloaded before onboarding saves, preserving unrelated settings.
- Open Settings from onboarding retains consent only in memory for that same
  account/session. On resume, permission is rechecked; only a grant proceeds to
  registration and saving. Closing Settings without granting changes nothing.
  Sign-out/account switching invalidates pending offers and Settings consent.
  Process death intentionally discards pending consent; users can enable from
  Notification Preferences after restart.
- The manual settings toggle remains the manual entry point. It shows current
  Android permission guidance, an Open Android Notification Settings action, and
  refreshes on resume. Opening Settings manually does not silently enable an off
  account preference: return and enable the toggle. Manual opt-outs on this
  installation are recorded and suppress onboarding.

## Schema limitation

notification_preferences.push_enabled defaults to false and has no separate
explicit-choice flag. created_at/updated_at also change for category settings,
so they cannot reliably establish deliberate opt-out. A prior opt-out on another
installation cannot be distinguished from the default. This implementation never
silently changes false to true: a fresh installation may show one explanation,
and only an explicit Enable/Open Settings consent can enable it. A known manual
opt-out on this installation is suppressed. No database change is necessary.

## Architecture / changed files

- android/app/src/main/kotlin/com/example/skilltrack/MainActivity.kt: Android
  permission snapshot, rationale, Settings intent and no-backup local state.
- lib/features/notifications/services/notification_installation_service.dart:
  injectable Android-only service boundary; safe supported check on other targets.
- lib/features/notifications/viewmodels/push_notification_controller.dart:
  onboarding decisions, consent/race guards, Settings reconciliation, existing
  permission and device-registration orchestration.
- lib/features/notifications/widgets/push_permission_onboarding.dart: small
  explanation dialog and authenticated-route presenter using the existing
  navigator/route observer. Invalid offers cannot act on a different account.
- lib/features/notifications/viewmodels/notification_preferences_view_model.dart
  and views/notification_preferences_screen.dart: manual opt-out recording,
  denied-permission guidance, Settings action and resume refresh, account guards.
- lib/app/router/app_router.dart, lib/app/skill_track_app.dart, lib/main.dart:
  authenticated host wiring, resume reconciliation, production service injection.
- lib/core/constants/app_constants.dart: shared onboarding copy.
- test/features/notifications/permission_onboarding_test.dart: focused fixtures.
- test/features/notifications/push_notification_test.dart: existing subtitle
  assertion now accepts the added Android guidance.
- test/device/notification_permission_probe.dart: offline-only native smoke target.
  Do NOT install this target under the production application ID.

## Verification

Focused fixtures cover first auth, existing granted permission/preference,
explicit consent, Not Now across controller recreation, a different installation,
previous denial/retry/Settings return, returning without granting, manual opt-out,
new account on the same installation, duplicate checks/accepts, account changes
before/during requests and Settings, disposal, permission/token/registration/save
failures, a usable main screen on failure, and manual Settings-resume guidance.
Platform-channel tests verify local method contracts without calling Firebase.

Observed native smoke checks used connected emulator-5554 (Android API 37) and
an isolated `com.example.skilltrack.permissionprobe` application ID. Original
SkillTrack applicationId, Firebase config and manifest were restored byte-for-byte
after building the probe. No Supabase/Firebase token repositories ran in the probe.

Observed:
- Fresh installation: granted=false, canRequest=true, handled=false.
- Actual native Not Now write survived process restart (handled=true).
- Simulated first-denial flags: canRequest=true after the first recorded request.
- Simulated fixed-denial flags: canRequest=false, leading to Settings guidance.
- Real notification Settings intent opened Android AppNotificationSettingsActivity.
- After granting only the probe permission with adb, native read returned
  granted=true, canRequest=false, handled=true.

These were native state/Settings-intent smoke checks with controlled adb flags,
not manual taps on the actual Android permission dialog. Firebase permission
transport behavior, real FCM token registration/delivery, a hosted authenticated
onboarding save, physical-device behavior and Android 12/below were not exercised.
All server writes in automated tests used isolated fake repositories.

Final results (2026-11-13):
- `flutter analyze`: passed, no issues.
- `flutter test`: 584 passed, including 26 focused onboarding tests and existing push/authentication regressions.
- `flutter build apk --debug`: passed; normal app APK is 158842861 bytes.
- `git diff --check`: passed.
- Disposable probe package was uninstalled after observations. The real app was not reinstalled or run against hosted data.
- Original Android Gradle/application ID and google-services.json are unchanged; no new package dependencies.

Debug APK: `build/app/outputs/flutter-apk/app-debug.apk`. Its compiled entry point
was checked to include the normal onboarding host and exclude the offline probe.
The existing local public Supabase configuration is preserved and remains ignored
by Git. The build has not been manually exercised through a real hosted login or
FCM registration during this task.

## Rebuild / use

This adds native Android code, so hot reload is insufficient. Fully stop the
old run, then rebuild/reinstall the normal app:

```powershell
Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack - final'
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

No new Android permission declaration is required: POST_NOTIFICATIONS already
exists. No new dependencies, migrations or Edge deployments are required.
Do not clear real app data to test onboarding; use a separate test installation.
The existing no-backup record intentionally prevents repeated automatic prompts.
Users can always use Notification Preferences to enable later.

Platform references:
- [Firebase permission behavior](https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages)
- [Android runtime permission guidance](https://developer.android.com/training/permissions/requesting)
