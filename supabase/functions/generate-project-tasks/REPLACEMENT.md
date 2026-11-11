# Regenerate Task List (CLQ)

The Kanban menu exposes a separate Regenerate Task List action. Feedback is
required (1–1000 trimmed characters). Saved project fields, constraints, dates,
existing milestones and up to 100 task summaries supply the bounded AI context.
The existing preview supports edits, removal, ordering within milestone groups
and follow-up revision. Old titles are permitted in replacement mode.

No tasks change during generation or preview. Confirm Replacement asks explicitly
how many active tasks will be archived, including manual and completed tasks.
Already archived tasks are untouched. Old IDs, milestone memberships, completed
state, histories, tags, attachments, bookmarks and recommendations are retained.
Active timers settle their elapsed seconds and stop. Replacement tasks start in
To-Do with checklists and Malaysia end-of-day deadlines. Existing milestones are
retained; same-title new groups reuse a project milestone rather than creating
another group with that title. Existing milestone IDs remain ownership checked.
Normal board reload recalculates active counts/progress. Archived tasks remain
excluded by existing monitoring/notification eligibility rules.

## Transaction and retries

Migration 016 adds functions only: no tables or columns. It reuses the existing
kanban_write_requests receipts. Snapshot versions include the project, all board
task rows, project milestones and task checklists. A changed snapshot rejects
confirmation. Cancel and start again to capture a new snapshot.

The confirmation transaction briefly locks the affected table types to exclude
writers that do not use the board lock (especially checklist writes). These are
global table locks, so simultaneous board saves can briefly wait. There are no
locks held during AI generation or preview. A future optimization could align
all writers on one board-lock protocol; it is outside this focused change.

Archival, activity, milestones, tasks, checklists and both receipts commit or roll
back together. The internal insertion helper is not executable by clients. The
public RPC checks auth.uid(), board ownership, active project/board and payload
identity. A retry after commit returns the original count before checking the
old snapshot; concurrent confirmation cannot archive twice. Same ID/different
payload is rejected. Flutter freezes its draft and ID after the first save
attempt. Retry recovery in Flutter lasts while that preview is open; IDs are
not persisted across app restarts. Close/reopen reloads the committed board.

## Rollout (not executed)

1. Verify the actual base schema and existing migrations:
   atomic_kanban_writes, project_milestones, task_generated_deadline_malaysia,
   task_time_tracking, task_meaningful_progress, task_write_consistency and
   atomic_project_and_task_actions, with their prerequisites.
2. Apply supabase/migrations/016_replace_generated_task_list.sql once using
   SQL Editor or the existing migration process. Migration 015 is unrelated to
   this feature and is not a prerequisite for replacement.
3. Deploy the updated existing function:

   npx supabase functions deploy generate-project-tasks

4. Rebuild Flutter. No new secret, scheduler or package is needed.

## Verification and acceptance

Automated checks use fake AI and local PGlite with checked-in functions and a
minimal ownership/RLS schema fixture. The repository lacks a complete canonical
base schema, so these are not hosted production-schema or multi-connection
concurrency verification. Dependencies are retained because no old task is
removed; attachment/bookmark retention still needs the hosted acceptance check.
No real Gemini generation or live deployment was performed for this change.

In a disposable authorized project, include To-Do, timed In Progress, Completed,
manual and already archived tasks, with bookmarks/attachments/checklists. Generate
and cancel a replacement: all saved data must stay unchanged. Generate again,
edit/revise, confirm, and check old active tasks in Archive with their history,
bookmarks and attachments and stopped timers. New tasks/checklists must appear
once. Repeat after a simulated lost response. Edit a checklist while preview is
open: confirmation must reject it without archiving any task. Confirm initial
generation and Generate More Tasks still behave as before.
