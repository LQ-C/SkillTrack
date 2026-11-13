> Latest storage-split results: [BUCKET_SPLIT_VALIDATION.md](BUCKET_SPLIT_VALIDATION.md) — 558 Flutter, 300 backend/SQL, 71 Deno and 25 worker tests passed; Android debug build passed.

# Local integration validation

Validated on 2026-11-12 in `codex/marketplace-integration`.

| Check | Result |
| --- | --- |
| flutter pub get | Passed; lockfile updated for imported packages |
| flutter analyze | Passed, no issues |
| flutter test | 542 passed |
| Android debug APK | Built successfully |
| Node backend and PGlite SQL fixture suite | 292 passed |
| Deno analysis/recommendation/push/cleanup fixtures | 69 passed |
| Imported and changed Edge entry-point type checks | Passed |
| Python extraction worker | 23 discovered: 22 passed, 1 optional native-PDF check skipped |
| git diff --check | Passed; Windows line-ending advisories only |
| Historical SkillTrack migrations | Preserved, compared against HEAD |
| Copied SQL credential-pattern check | Passed |

APK: `build/app/outputs/flutter-apk/app-debug.apk` (debug build, 182423244 bytes).
It displays setup until configured with the chosen integration project's public
client configuration. No integration-project keys were supplied during this work.

Fixtures cover login/logout and account switching against one Supabase client,
project/task/recommendation owner IDs, recovery redirect and private tab-state
reset; auth/profile validation and mentor roles; five-tab retention and duplicate
callbacks; resource-details navigation and private-media URL signing; marketplace
library/editor, access, mentor/payment/session/feedback behavior; existing project
creation/generation/revision/replacement, Kanban, tracking and notifications.
Backend checks include SQL ownership contracts, extraction identity/version,
moderation, semantic recommendations, bookmarks, task-write consistency, push
handlers and bounded account-owned Storage cleanup. All writes used local
fixtures. No hosted payment or user account was created.

The original two push fixture timing failures were reproduced with the original
app lifecycle and corrected in test setup. Integration failures caused by the
file_picker upgrade, old tab indices and obsolete notification-tab assumptions
were fixed and their affected checks rerun. Final suites have no known failures.

Not verified here: target-schema restoration, existing-target data migration,
real email delivery/recovery links, actual video/PDF/image model execution,
external player apps, hosted RLS/realtime reconnect, Firebase delivery or physical
Android cold-start behavior. Docker's Linux engine was unavailable, so the full
combined-schema restoration fixture was not rerun. The additive compatibility
migration was validated separately in isolated PGlite fixtures. Supabase CLI
migration/deployment commands in MARKETPLACE_INTEGRATION.md were not executed.

No source-project schema, hosted Storage/data, secrets, cron or functions were
modified. No real payments, commits, pushes or deployments were executed.

Latest worker follow-up: [WORKER_VERIFICATION.md](WORKER_VERIFICATION.md) records 23/23 passing in the new local venv, actual CUDA video transcription, selectable PDF extraction and scanned-PDF OCR. The earlier skipped PDF check now passes with native dependencies installed. Hosted worker configuration remains outstanding.
