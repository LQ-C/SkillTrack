# Task-specific saved resources

Apply `supabase/migrations/012_task_resource_bookmarks.sql` in SQL Editor before
running the updated Flutter build. Requires the existing UUID task/resource
schema; migrations 009-011 remain the recommendation feature prerequisites.
This migration adds task_resource_bookmarks (task_id, resource_id, created_at),
its RLS policies, and three functions. No Edge Function deployment is needed.
Do not change marketplace SELECT policies to make this feature work.

Bookmarks load separately from recommendations at the Task Details route boundary.
The existing injected SupabaseRecommendationRepository implements BookmarkRepository.
A separate ViewModel owns saved state; recommendation replacement or Resume Task
does not clear it. Completed/archived tasks retain readable links and owners can
remove them, but new saves require an active project/board and incomplete,
unarchived task. A hidden, archived or RLS-inaccessible resource shows only
“Resource unavailable” and a remove button. Resource deletion cascades the link.

Writes express the desired saved state rather than toggling server state. The
pair primary key prevents duplicates; retries reuse that same pair/state. UI
changes only after a successful response, retaining previous state on failure.
Retry retries the failed write; reopening reloads the committed database state.
There is no recommendation history and no marketplace navigation.

Local database tests use a UUID schema fixture with marketplace RLS, not the
complete production schema. Live schema/grants and marketplace policies were not
queried. Before rollout verify learning_resources.id and kanban_tasks.id are UUID,
resource SELECT grants/policies match the recipient, and existing resource/task
DELETE paths permit the new cascading references. Test real account switching,
restart persistence and inaccessible-resource removal on a test project/device.
No live migrations or deployments were performed.
