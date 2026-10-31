-- SkillTrack: persistent task time tracking.
-- Run in Supabase Dashboard > SQL Editor, against the existing SkillTrack DB.
-- Adds two columns and one authenticated RPC. Does not alter RLS policies,
-- deadlines, stagnation scoring, notification generation or Resume Task.
-- Existing tasks begin with zero recorded time; historical time is not inferred.
-- Flutter must call this RPC for status changes and timer actions.

begin;

alter table public.kanban_tasks
  add column if not exists elapsed_seconds bigint not null default 0,
  add column if not exists tracking_started_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.kanban_tasks'::regclass
      and conname = 'kanban_tasks_elapsed_seconds_nonnegative'
  ) then
    alter table public.kanban_tasks
      add constraint kanban_tasks_elapsed_seconds_nonnegative
      check (elapsed_seconds >= 0);
  end if;
end;
$$;

create or replace function public.update_kanban_task_tracking(
  p_task_id uuid,
  p_action text,
  p_expected_updated_at timestamptz,
  p_status text default null,
  p_sort_order bigint default null
)
returns public.kanban_tasks
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_task public.kanban_tasks%rowtype;
  v_status public.kanban_tasks.status%type;
  v_order public.kanban_tasks.sort_order%type;
  v_started_at timestamptz;
  v_completed_at public.kanban_tasks.completed_at%type;
  v_elapsed bigint;
  v_now timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Sign in to update task tracking'
      using errcode = '42501';
  end if;

  if p_task_id is null or p_expected_updated_at is null
      or p_action is null or p_action not in ('move', 'pause', 'resume') then
    raise exception 'Invalid task tracking request'
      using errcode = '22023';
  end if;

  if p_action = 'move' then
    if p_status is null or p_status not in ('todo', 'in_progress', 'completed') then
      raise exception 'Invalid destination status' using errcode = '22023';
    end if;
  elsif p_status is not null or p_sort_order is not null then
    raise exception 'Timer actions cannot change status or ordering'
      using errcode = '22023';
  end if;

  -- Serialize changes to this task; RLS still applies to every statement.
  select t.* into v_task
  from public.kanban_tasks t
  join public.kanban_boards b on b.id = t.board_id
  join public.projects p on p.id = b.project_id
  where t.id = p_task_id
    and p.owner_id = auth.uid()
    and p.status <> 'archived'
    and not coalesce(b.is_archived, false)
    and not coalesce(t.is_archived, false)
  for update of t;

  if not found then
    raise exception 'Task unavailable' using errcode = '42501';
  end if;

  -- Read time after obtaining the row lock, not at transaction start.
  v_now := clock_timestamp();
  v_status := v_task.status;
  v_order := v_task.sort_order;
  v_started_at := v_task.tracking_started_at;
  v_completed_at := v_task.completed_at;
  v_elapsed := v_task.elapsed_seconds;

  if p_action = 'move' then
    v_status := p_status;
    v_order := coalesce(p_sort_order, v_task.sort_order);

    if v_status is distinct from v_task.status then
      v_started_at := case when p_status = 'in_progress' then v_now else null end;
      v_completed_at := case when p_status = 'completed' then v_now else null end;
    end if;
  else
    if v_task.status::text <> 'in_progress' then
      raise exception 'Only In Progress tasks can be paused or resumed'
        using errcode = '22023';
    end if;

    if p_action = 'pause' then
      v_started_at := null;
    else
      -- A repeated resume preserves the original session start.
      v_started_at := coalesce(v_task.tracking_started_at, v_now);
    end if;
  end if;

  -- Repeated pause/resume and unchanged moves are harmless no-ops.
  if v_status is not distinct from v_task.status
      and v_order is not distinct from v_task.sort_order
      and v_started_at is not distinct from v_task.tracking_started_at
      and v_completed_at is not distinct from v_task.completed_at then
    return v_task;
  end if;

  -- Reject stale mutations, including delayed requests from another device.
  -- Flutter must refresh the task before retrying a conflict.
  if v_task.updated_at is distinct from p_expected_updated_at then
    raise exception 'Task changed. Refresh it and try again.'
      using errcode = '40001';
  end if;

  -- Settle a running session exactly once when it stops or changes status.
  if v_task.tracking_started_at is not null
      and v_started_at is distinct from v_task.tracking_started_at then
    v_elapsed := v_elapsed + greatest(
      0::bigint,
      floor(extract(epoch from (v_now - v_task.tracking_started_at)))::bigint
    );
  end if;

  update public.kanban_tasks
  set status = v_status,
      sort_order = v_order,
      completed_at = v_completed_at,
      elapsed_seconds = v_elapsed,
      tracking_started_at = v_started_at,
      updated_at = v_now
  where id = v_task.id
  returning * into v_task;

  return v_task;
end;
$$;

revoke all on function public.update_kanban_task_tracking(
  uuid, text, timestamptz, text, bigint
) from public, anon;

grant execute on function public.update_kanban_task_tracking(
  uuid, text, timestamptz, text, bigint
) to authenticated;

notify pgrst, 'reload schema';

commit;

-- Verification (read-only): both columns and the RPC should appear.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'kanban_tasks'
  and column_name in ('elapsed_seconds', 'tracking_started_at')
order by column_name;

select p.proname as function_name, p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'update_kanban_task_tracking';
