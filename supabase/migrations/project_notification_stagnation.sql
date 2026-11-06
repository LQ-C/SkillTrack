-- Align the installed notification RPCs with the checked-in Edge Function.
-- Live pg_get_functiondef was unavailable: the verified caller uses
-- (p_task_id uuid, p_score integer, p_checked_at timestamptz) and the three
-- returned columns below. Incompatible installed definitions abort transactionally.
-- Apply AFTER project_notification_generator.sql. No cron/secret changes.
begin;

do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'update_task_stagnation'
      and p.oid <> coalesce(to_regprocedure(
        'public.update_task_stagnation(uuid,integer,timestamp with time zone)'), 0::oid)
  ) then
    raise exception 'Inspect installed update_task_stagnation signature before applying this migration';
  end if;
end;
$$;

-- These persisted fields are already used by Flutter; never add last_activity_at.
alter table public.kanban_tasks
  add column if not exists stagnation_score integer not null default 0,
  add column if not exists is_stalled boolean not null default false,
  add column if not exists stalled_at timestamptz,
  add column if not exists stagnation_checked_at timestamptz;

-- Monitoring is not user activity. Preserve the activity fallback even on
-- installations with an unconditional BEFORE UPDATE updated_at trigger.
-- The marker is transaction-local, task-specific and set only around the RPC write.
create or replace function public.preserve_stagnation_activity_timestamp()
returns trigger language plpgsql security invoker
set search_path = public, pg_temp as $$
begin
  if current_setting('skilltrack.stagnation_task_id', true) = old.id::text
    and (to_jsonb(new) - array['stagnation_score', 'is_stalled', 'stalled_at',
      'stagnation_checked_at', 'updated_at']) =
        (to_jsonb(old) - array['stagnation_score', 'is_stalled', 'stalled_at',
          'stagnation_checked_at', 'updated_at']) then
    new.updated_at := old.updated_at;
  end if;
  return new;
end;
$$;
revoke all on function public.preserve_stagnation_activity_timestamp()
  from public, anon, authenticated;

drop trigger if exists zz_preserve_stagnation_activity_timestamp on public.kanban_tasks;
create trigger zz_preserve_stagnation_activity_timestamp
  before update on public.kanban_tasks for each row
  execute function public.preserve_stagnation_activity_timestamp();

create or replace function public.update_task_stagnation(
  p_task_id uuid, p_score integer, p_checked_at timestamptz)
returns table (
  became_stalled boolean, currently_stalled boolean, current_stalled_at timestamptz)
language plpgsql security invoker
set search_path = public, pg_temp set timezone = 'UTC' as $$
declare
  task public.kanban_tasks%rowtype;
  latest_activity timestamptz;
  previous_marker text;
  next_stalled boolean;
  next_stalled_at timestamptz;
begin
  if p_task_id is null or p_score is null or p_score not between 0 and 100
    or p_checked_at is null or not isfinite(p_checked_at) then
    raise exception 'Invalid stagnation update' using errcode = '22023';
  end if;

  select t.* into task
  from public.kanban_tasks t
  join public.kanban_boards b on b.id = t.board_id
  join public.projects p on p.id = b.project_id
  join public.profiles pr on pr.id = p.owner_id
  where t.id = p_task_id and p.status = 'active'
    and not coalesce(b.is_archived, false)
    and not coalesce(t.is_archived, false) and t.status <> 'completed'
  for update of t;
  if not found then
    raise exception 'Task is not eligible for stagnation processing' using errcode = 'P0002';
  end if;

  select max(l.created_at) into latest_activity
  from public.task_activity_logs l where l.task_id = p_task_id;

  -- checked_at is the generator's injected run-start clock, before fetching
  -- candidates. Do not persist a calculation superseded by activity or a newer run.
  if task.updated_at >= p_checked_at or latest_activity >= p_checked_at
    or task.created_at >= p_checked_at or task.stagnation_checked_at > p_checked_at then
    raise exception 'Stale stagnation calculation; retry with fresh candidates'
      using errcode = '40001';
  end if;

  next_stalled := p_score >= 70;
  next_stalled_at := case when next_stalled then
    case when coalesce(task.is_stalled, false) then
      coalesce(task.stalled_at, p_checked_at) else p_checked_at end
    else null end;

  previous_marker := current_setting('skilltrack.stagnation_task_id', true);
  perform set_config('skilltrack.stagnation_task_id', p_task_id::text, true);
  update public.kanban_tasks t set
    stagnation_score = p_score, is_stalled = next_stalled,
    stalled_at = next_stalled_at, stagnation_checked_at = p_checked_at
  where t.id = p_task_id;
  perform set_config('skilltrack.stagnation_task_id', coalesce(previous_marker, ''), true);

  -- Unknown live trigger definitions must fail safely rather than turn a
  -- background calculation into activity and reset the score on the next run.
  if exists (select 1 from public.kanban_tasks t where t.id = p_task_id
      and t.updated_at is distinct from task.updated_at)
    or (select max(l.created_at) from public.task_activity_logs l
      where l.task_id = p_task_id) is distinct from latest_activity then
    raise exception 'A task trigger changes activity during stagnation updates; inspect task triggers'
      using errcode = '55000';
  end if;

  return query select next_stalled and not coalesce(task.is_stalled, false),
    next_stalled, next_stalled_at;
end;
$$;

revoke all on function public.update_task_stagnation(uuid, integer, timestamptz)
  from public, anon, authenticated;
grant execute on function public.update_task_stagnation(uuid, integer, timestamptz)
  to service_role;

-- Adding a RETURNS TABLE column cannot use CREATE OR REPLACE. Deliberately
-- avoid CASCADE: unknown dependent objects require inspection, not deletion.
drop function if exists public.notification_task_candidates(integer, integer);
create function public.notification_task_candidates(
  p_offset integer, p_limit integer)
returns table (
  task_id uuid, board_id uuid, project_id uuid, user_id uuid,
  task_title text, task_status text, task_archived boolean,
  board_archived boolean, project_status text, profile_exists boolean,
  deadline text, last_activity_at text, task_created_at text)
language sql stable security invoker
set search_path = public, pg_temp set timezone = 'UTC' as $$
  select t.id, b.id, p.id, p.owner_id, t.title::text, t.status::text,
    coalesce(t.is_archived, false), coalesce(b.is_archived, false),
    p.status::text, pr.id is not null, t.deadline::text,
    coalesce(activity.created_at, t.updated_at, t.created_at)::text, t.created_at::text
  from public.kanban_tasks t
  join public.kanban_boards b on b.id = t.board_id
  join public.projects p on p.id = b.project_id
  left join public.profiles pr on pr.id = p.owner_id
  left join lateral (
    select l.created_at from public.task_activity_logs l
    where l.task_id = t.id
    order by l.created_at desc limit 1
  ) activity on true
  where p.status = 'active' and not coalesce(b.is_archived, false)
    and not coalesce(t.is_archived, false) and t.status <> 'completed'
  order by t.id
  offset greatest(p_offset, 0)
  limit least(greatest(p_limit, 1), 500);
$$;


revoke all on function public.notification_task_candidates(integer, integer)
  from public, anon, authenticated;
grant execute on function public.notification_task_candidates(integer, integer)
  to service_role;
commit;
