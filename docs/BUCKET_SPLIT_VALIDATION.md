# Bucket split validation — 2026-11-12

Validated in `C:\Users\PC\Documents\FYP\SkillTrack - final`, branch
`codex/marketplace-integration`. All previous uncommitted integration work was
retained. No commit, push or branch reset was performed.

| Check | Measured result |
| --- | --- |
| Flutter analysis | No issues |
| Full Flutter suite | 558 passed |
| Full backend/SQL fixture suite | 300 passed |
| Deno analysis/recommendation/notification/cleanup suites | 71 passed |
| Changed Edge entry-point type checks | Passed |
| Python worker suite in integrated venv | 25 passed, no skips |
| Native local processing | MP4 transcription, selectable PDF and scanned-PDF OCR passed |
| Android debug build | Passed; build/app/outputs/flutter-apk/app-debug.apk |
| git diff --check | Passed |
| Historical SkillTrack and teammate migrations | Preserved and compared against source |

The 16 new Flutter tests cover all five upload extensions, stable references,
new/legacy MP4 signing, path-only legacy videos, PDF/image signing, unsupported
and oversized files, empty uploads, wrong kinds/buckets, invalid references,
foreign hosts, traversal, and signature denial without another-bucket fallback.
The full suite retains YouTube, editor, session/profile, task attachments,
recommendations/bookmarks, notification and task-management checks.

The split SQL fixture uses the real canonical entitlement functions extracted
from the reference schema. It verifies both bucket privacy flags/configuration
locally, existing object identity preservation, author and paid learner reads,
denial for unpaid/other-mentor/anonymous/unverified/refunded/session-only users,
moderation/drafts, correct upload bucket/path/extension, resource-reference
constraints, immutable objects, wrong-bucket duplicate paths and unaffected task
attachment ownership. An intentionally broad permissive policy is present to
ensure restrictive boundaries still enforce resource access.

Worker/Edge tests cover new mentor-video-files references and legacy reading/
marketplace-video references, extraction identity/version and stale-source
checks, and rejection of foreign/signed/traversal/wrong-kind references. Account
cleanup tests cover both resource buckets and preserve other owners. Native smoke
checks ran process_one with synthetic local files and a local gateway only; they
did not contact Supabase. The diagnostic's Video fixture uses mentor-video-files;
PDF/OCR fixtures use mentor-reading-files.

Hosted limits: the supplied screenshot confirms existence/MIME lists/policy
counts, but not public flags. Dashboard inspection timed out waiting for access.
Both LIVE public/private flags therefore remain unverified. The prepared
read-only audit SQL checks each bucket separately. No hosted migration, policy
edit, bucket creation/reconfiguration, function deployment, file copy/move/delete,
reference backfill, payment, cron invocation or extraction-worker run occurred.
`--once` was not used against a hosted queue. Live RLS/storage signing, actual
uploads, cloud Gemini/gte-small inference, physical-device playback and push
behavior still require an isolated configured target/device.

No remaining local test/build failures are known. A PostgREST mock response needed
its originating request attached, and Dart URI normalization required rejecting
raw dot segments before parsing; both findings were fixed and affected/full
suites rerun. No new pre-existing production defect was identified by this split.

See RESOURCE_BUCKET_SPLIT.md for precise migration/configuration/deployment steps,
compatibility decisions and an optional separately reviewed old-video migration.
