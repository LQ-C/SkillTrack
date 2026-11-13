# Read-only live recheck — 2026-11-13

Project twvnybxdmqabgwcsksop:
- resource-analysis-queue ACTIVE, version 2.
- delete-account ACTIVE, version 1.
- mentor-reading-files public=false, 10 MiB, PDF/PNG/JPEG.
- mentor-video-files public=false, 50 MiB, MP4.
- 018 typed upload/read boundaries, immutable-object and anonymous policies,
  and the split resource_link constraint are present.

Defect found: authenticated has no EXECUTE on resource_analysis_storage_key(text),
which the new read policies/constraint call. The previous fixture accidentally
retained PostgreSQL's default PUBLIC EXECUTE and missed this production ACL.
Prepared 019_resource_storage_policy_helper_permission.sql locally. It grants
only authenticated EXECUTE on the pure immutable SECURITY INVOKER URL parser;
it does not read tables or change file entitlements. The fixture now revokes the
PUBLIC default before applying 019 and checks authenticated/anonymous ACLs.

Apply 019 once in SQL Editor on this project, then rerun the read-only audit.
No Edge redeployment is needed for this permission fix. No live mutations or
function invocations were performed by this recheck. Function ACTIVE status does
not establish end-to-end upload/playback/worker behavior or exact bundle parity.
