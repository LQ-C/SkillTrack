# Two private resource buckets — local implementation

Implemented on codex/marketplace-integration, preserving its prior uncommitted
integration work. No other original project folder was modified.

## Result and compatibility decisions

- New PDF/PNG/JPG/JPEG uploads use mentor-reading-files (10 MiB, matching the
  existing editor). New MP4 uploads use mentor-video-files (50 MiB).
- The existing model is sufficient: attachment_path is the object path and
  external_url is a stable authenticated Storage reference containing its bucket.
  No new model column or parallel repository was introduced.
- Signed opening resolves the validated stored reference FIRST. Old path-only
  records fall back to mentor-reading-files, including MP4. No extension-based
  assumption relocates older videos. Foreign hosts, queries/signed source URLs,
  traversal, mismatched attachment paths and bucket/type mismatches fail closed.
  A denied signature request is not retried in another bucket.
- YouTube remains inline; external links are not uploaded to Storage. Existing
  screen structures, field order, controls, booking/payment flow and task layouts
  are unchanged. Task and marketplace bookmarks remain separate.
- Worker and analysis source resolution accept the new video bucket plus legacy
  mentor-reading-files/marketplace-videos. PDF/image handling remains in reading
  buckets. Extraction identity/version, leases/retries, current-source validation
  and semantic-index logic are unchanged. Account cleanup includes both buckets.
- Migration 018 replaces only the known old resource Storage policies, retains
  can_read_mentor_resource payment/publication/moderation checks, and matches both
  bucket and path to the accessible resource. Restrictive boundaries prevent
  broader permissive policies from bypassing the two resource buckets. Client
  object UPDATE is blocked: edits upload a new random path, then update the owned
  resource. This preserves the existing immutable-file workflow and provenance.
  Existing task attachment policies are unaffected.
- Historical migrations (including 017) and the schema-only snapshot remain
  intact. Apply the NEW 018 after the target's canonical schema and 017.

## Live inspection status

The supplied screenshot shows both buckets already exist, video has zero
policies, and reading has two policies. It shows MP4 vs PDF/image MIME lists and
an unset size limit with a displayed 50 MB default. It does NOT show either
bucket's public/private flag. Do not infer privacy from zero policies or names.

A read-only attempt to inspect the authenticated SkillTrack dashboard timed out
waiting for computer-use access. No live setting was read/changed through that
attempt. Live privacy for EACH bucket therefore remains UNVERIFIED.

`supabase/setup/audit_mentor_resource_buckets.sql` separately selects existence,
public/is_private, limits and MIME lists for BOTH buckets, then displays Storage
policies and aggregate legacy-reference counts. It is read-only and prints no
keys, signed URLs or object contents. Run it on the chosen target before approval
of any hosted changes. Local fixtures independently verify both public flags
are false after the prepared migration, not that the live flags are false now.

## Exact target rollout (prepared only; NOT executed)

1. Back up the chosen integration target and confirm Flutter and the extraction
   worker use that same project. Run the entire read-only audit script first.
   Review ALL Storage policies, including role-wide/ALL policies and any older
   restrictive policy that could deny otherwise legitimate reads.
2. Ensure the canonical profiles/resources/paid-access schema, extraction schema,
   and migration 017 equivalents are installed. For a fresh database only, follow
   MARKETPLACE_INTEGRATION.md's guarded combined-schema bootstrap. Never run the
   bootstrap or replay historical migrations over a populated source database.
3. Review and run the complete transaction in:
   `supabase/migrations/018_split_mentor_resource_buckets.sql`.
   Both existing buckets are retained; ON CONFLICT does nothing. Only a missing
   bucket is created. Their future-upload MIME/size/privacy configuration is set
   explicitly; object IDs, files and resource rows are not moved/deleted/backfilled.
   The migration preserves existing reading-bucket MP4 reads while disallowing
   NEW MP4 uploads there. It provides video INSERT and SELECT policies even if
   the video bucket currently has zero policies.

   If using an administrative psql connection instead of the SQL Editor:

   ```powershell
   psql "$env:INTEGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/setup/audit_mentor_resource_buckets.sql
   psql "$env:INTEGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/018_split_mentor_resource_buckets.sql
   psql "$env:INTEGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/setup/audit_mentor_resource_buckets.sql
   ```

   Set the connection string privately in the environment; never paste it into
   source/logs/chat. These commands were NOT run. The setup script
   marketplace_private_buckets.sql also knows both buckets for fresh setup; it
   does not replace migration 018's policies.
4. After explicit authorization, deploy the two changed Edge entry points only:

   ```powershell
   npx --yes supabase@3.1.0 functions deploy resource-analysis-queue --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
   npx --yes supabase@3.1.0 functions deploy delete-account --remote=YOUR_PROJECT_REF --use-api --no-verify-jwt
   ```

   Keep their existing server-side authentication/secret checks. Other Edge
   functions and semantic ranking algorithms need no deployment for this split.
5. Worker .env.example now uses VIDEO_BUCKET=mentor-video-files. The worker also
   recognizes legacy marketplace-videos and mentor-reading-files references,
   independent of that primary setting. Keep PDF_BUCKET=marketplace-documents
   when legacy documents exist; mentor-reading-files is recognized as well.
   Keep existing RESOURCE_VIDEO_BUCKET/RESOURCE_PDF_BUCKET/RESOURCE_IMAGE_BUCKET
   Edge settings for their legacy buckets: new mentor video references are
   resolved directly, and the mentor reading image drain is unchanged.
6. After target configuration and authorization, stop/restart the extraction
   worker using this checkout's local venv, then release the updated Flutter app:

   ```powershell
   Set-Location 'C:\Users\PC\Documents\FYP\SkillTrack - final\workers\content_analysis\speech-to-text'
   & '..\.venv\Scripts\python.exe' -m skilltrack_speech.worker
   ```

   This command claims/writes hosted jobs, as does --once. Neither was run here.
7. On an isolated target, verify new PDF/image/video uploads, old video playback,
   signature denial for unpaid users, moderation, actual file processing and
   task recommendations. Fixture success does not verify hosted/device behavior.

## Existing files and optional later migration

No immediate file migration is required. Existing references continue to work.
If pre-split attachment records have an empty external_url, the guarded
normalize_existing_attachments.sql still points them at mentor-reading-files,
including videos, because that is where those objects were originally uploaded.
Do not run it on newly split resources or change its bucket based on file type.

Any later move of old videos needs a separate reviewed manifest of resource ID,
source bucket/path/object ID/version and destination. Copy only to a private
bucket with the same access rules, verify bytes and entitled reads, then update
the resource reference transactionally while handling concurrent edits. Keep
source files until references/readers/jobs have been audited. Copying can change
Storage identity/version; expect fresh extraction, analysis and embeddings even
if bytes are identical. Never reuse old extraction provenance for the new object.
No copy, move, reference backfill or cleanup was executed in this task.

## Reproduce local validation

```powershell
flutter analyze
flutter test
flutter build apk --debug
npm --prefix supabase/tests ci --ignore-scripts
npm --prefix supabase/tests test
npx --yes deno@2.9.6 test --no-lock supabase/functions/resource-analysis-queue supabase/functions/recommend-resources supabase/functions/_shared/recommendations supabase/functions/project-notification-generator/recommendations.test.ts supabase/functions/project-push-notification-dispatcher supabase/functions/delete-account/storage_cleanup.test.ts
npx --yes deno@2.9.6 check supabase/functions/resource-analysis-queue/index.ts supabase/functions/delete-account/index.ts
& '.\workers\content_analysis\.venv\Scripts\python.exe' -B -m unittest discover -s workers/content_analysis/speech-to-text/tests -t workers/content_analysis/speech-to-text -v
& '.\workers\content_analysis\.venv\Scripts\python.exe' -B '.\workers\content_analysis\speech-to-text\check_local.py' --video '.\workers\content_analysis\output\worker-check\fixture.mp4'
```

All SQL/HTTP writes in tests are isolated fixtures. The native smoke checks use
synthetic local MP4/PDF/OCR data through process_one, without a hosted queue.
See BUCKET_SPLIT_VALIDATION.md for final results and remaining verification.
