-- Apply after atomic_kanban_writes.sql. Additive: existing tasks remain ungrouped.
-- Safe to rerun after a failed or partially applied manual installation.
begin;
do $prerequisites$
begin
  if to_regclass('public.kanban_write_requests') is null
      or to_regprocedure('public.assert_owned_kanban_board(uuid)') is null
      or to_regprocedure('public.save_generated_tasks(uuid,text,jsonb)') is null then
    raise exception 'Run the complete atomic_kanban_writes.sql setup before project_milestones.sql'
      using errcode = '55000';
  end if;
end;
$prerequisites$;
create table if not exists public.project_milestones (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null check (length(btrim(title)) > 0 and length(title) <= 150),
  position integer not null default 0 check (position >= 0),
  created_at timestamptz not null default now()
);
alter table public.kanban_tasks add column if not exists milestone_id uuid
  references public.project_milestones(id) on delete set null;
create index if not exists project_milestones_project_position_idx
  on public.project_milestones(project_id, position, id);
create index if not exists kanban_tasks_milestone_idx on public.kanban_tasks(milestone_id);
alter table public.project_milestones enable row level security;
drop policy if exists project_milestones_select on public.project_milestones;
create policy project_milestones_select on public.project_milestones for select to authenticated
  using (exists (select 1 from public.projects p where p.id = project_id and p.owner_id = auth.uid()));
drop policy if exists project_milestones_insert on public.project_milestones;
create policy project_milestones_insert on public.project_milestones for insert to authenticated
  with check (exists (select 1 from public.projects p where p.id = project_id and p.owner_id = auth.uid() and p.status <> 'archived'));
drop policy if exists project_milestones_update on public.project_milestones;
create policy project_milestones_update on public.project_milestones for update to authenticated
  using (exists (select 1 from public.projects p where p.id = project_id and p.owner_id = auth.uid() and p.status <> 'archived'))
  with check (exists (select 1 from public.projects p where p.id = project_id and p.owner_id = auth.uid() and p.status <> 'archived'));
drop policy if exists project_milestones_delete on public.project_milestones;
create policy project_milestones_delete on public.project_milestones for delete to authenticated
  using (exists (select 1 from public.projects p where p.id = project_id and p.owner_id = auth.uid() and p.status <> 'archived'));
revoke all on public.project_milestones from public, anon, authenticated;
grant select, insert, update, delete on public.project_milestones to authenticated;

-- Enforce membership on ordinary task writes as well as generated batches.
create or replace function public.check_task_milestone_project() returns trigger
language plpgsql security invoker set search_path = public, pg_temp as $$
declare board_project uuid;
begin
  if new.milestone_id is not null then
    select project_id into board_project from public.kanban_boards where id = new.board_id for share;
    if not exists (select 1 from public.project_milestones m
        where m.id = new.milestone_id and m.project_id = board_project) then
      raise exception 'Milestone unavailable for this project' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists kanban_tasks_milestone_project on public.kanban_tasks;
create trigger kanban_tasks_milestone_project before insert or update of milestone_id, board_id
  on public.kanban_tasks for each row execute function public.check_task_milestone_project();

create or replace function public.keep_milestone_project() returns trigger
language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  if new.project_id is distinct from old.project_id then
    raise exception 'A milestone cannot be transferred to another project' using errcode = '23514';
  end if;
  return new;
end;
$$;
drop trigger if exists project_milestones_keep_project on public.project_milestones;
create trigger project_milestones_keep_project before update of project_id on public.project_milestones
  for each row execute function public.keep_milestone_project();

create or replace function public.keep_board_milestone_project() returns trigger
language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  if new.project_id is distinct from old.project_id and exists (
    select 1 from public.kanban_tasks t where t.board_id = old.id and t.milestone_id is not null
  ) then
    raise exception 'A board with milestone tasks cannot be transferred' using errcode = '23514';
  end if;
  return new;
end;
$$;
drop trigger if exists kanban_boards_keep_milestone_project on public.kanban_boards;
create trigger kanban_boards_keep_milestone_project before update of project_id on public.kanban_boards
  for each row execute function public.keep_board_milestone_project();

create or replace function public.save_generated_tasks_with_milestones(
  p_board_id uuid, p_request_id text, p_tasks jsonb
) returns integer language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  receipt public.kanban_write_requests;
  draft jsonb;
  task_id uuid;
  next_order bigint;
  saved integer := 0;
  checklist jsonb;
  normalized_title text;
  project uuid;
  milestone jsonb;
  milestone_key text;
  milestone_uuid uuid;
  milestone_map jsonb := '{}'::jsonb;
  milestone_metadata jsonb := '{}'::jsonb;
  next_position integer;
  versioned_payload jsonb := jsonb_build_object('format', 'milestones-v1', 'tasks', p_tasks);
begin
  if auth.uid() is null or p_request_id is null
      or length(p_request_id) not between 16 and 128
      or jsonb_typeof(p_tasks) is distinct from 'array'
      or jsonb_array_length(p_tasks) not between 1 and 12 then
    raise exception 'Invalid generated task request' using errcode = '22023';
  end if;
  -- Serialize a request across boards as well as concurrent writers to a board.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_request_id, 0));
  perform public.assert_owned_kanban_board(p_board_id);
  select * into receipt from public.kanban_write_requests
    where user_id = auth.uid() and request_id = p_request_id;
  if found then
    if receipt.board_id <> p_board_id or receipt.payload <> versioned_payload then
      raise exception 'Request identifier already used for another payload' using errcode = '22023';
    end if;
    return receipt.saved_count;
  end if;
  select project_id into project from public.kanban_boards where id = p_board_id;
  -- Serialize milestone positions across boards of the same project.
  perform 1 from public.projects where id = project for update;
  select coalesce(max(position), -1) + 1 into next_position
    from public.project_milestones where project_id = project;
  select coalesce(max(sort_order), 0) into next_order
    from public.kanban_tasks where board_id = p_board_id
      and status = 'todo' and not is_archived;
  for draft in select value from jsonb_array_elements(p_tasks) loop
    checklist := coalesce(draft->'checklist', '[]'::jsonb);
    if jsonb_typeof(draft) is distinct from 'object'
        or jsonb_typeof(draft->'title') is distinct from 'string'
        or length(btrim(draft->>'title')) not between 1 and 150
        or jsonb_typeof(draft->'description') is distinct from 'string'
        or length(btrim(draft->>'description')) not between 1 and 1000
        or coalesce(draft->>'priority', '') not in ('low', 'medium', 'high')
        or coalesce(draft->>'deadline', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        or jsonb_typeof(checklist) is distinct from 'array' then
      raise exception 'Invalid generated task' using errcode = '22023';
    end if;
    -- Casting rejects invalid calendar dates; the transaction is rolled back.
    perform (draft->>'deadline')::date;
    if jsonb_array_length(checklist) > 5 or exists (
      select 1 from jsonb_array_elements(checklist) item
      where jsonb_typeof(item) <> 'string'
        or length(btrim(item #>> '{}')) not between 1 and 150
    ) or (select count(distinct lower(btrim(value #>> '{}')))
          from jsonb_array_elements(checklist)) <> jsonb_array_length(checklist) then
      raise exception 'Invalid generated checklist' using errcode = '22023';
    end if;
    milestone_uuid := null;
    milestone := draft->'milestone';
    if milestone is not null and milestone <> 'null'::jsonb then
      milestone_key := milestone->>'localId';
      if jsonb_typeof(milestone) is distinct from 'object'
          or coalesce(length(btrim(milestone_key)), 0) not between 1 and 128
          or jsonb_typeof(milestone->'title') is distinct from 'string'
          or length(btrim(milestone->>'title')) not between 1 and 150
          or coalesce(milestone->>'position', '') !~ '^[0-9]+$'
          or (milestone->>'position')::bigint > 2147483647 then
        raise exception 'Invalid milestone' using errcode = '22023';
      end if;
      if milestone_metadata ? milestone_key and milestone_metadata->milestone_key <> milestone then
        raise exception 'Inconsistent milestone identity' using errcode = '22023';
      end if;
      milestone_metadata := milestone_metadata || jsonb_build_object(milestone_key, milestone);
      if (select count(*) from jsonb_object_keys(milestone_metadata)) > 5 then
        raise exception 'Too many milestones' using errcode = '22023';
      end if;
      if nullif(milestone->>'existingMilestoneId', '') is not null then
        select id into milestone_uuid from public.project_milestones
          where id = (milestone->>'existingMilestoneId')::uuid and project_id = project;
        if not found then
          raise exception 'Milestone unavailable for this project' using errcode = '42501';
        end if;
      end if;
    end if;
    normalized_title := regexp_replace(lower(btrim(draft->>'title')), '[^[:alnum:]]+', ' ', 'g');
    if exists (select 1 from public.kanban_tasks t where t.board_id = p_board_id
      and regexp_replace(lower(btrim(t.title)), '[^[:alnum:]]+', ' ', 'g') = normalized_title) then
      continue;
    end if;
    -- Create only groups containing at least one new task, after duplicate validation.
    if milestone is not null and milestone <> 'null'::jsonb and milestone_uuid is null then
      milestone_uuid := (milestone_map->>milestone_key)::uuid;
      if milestone_uuid is null then
        insert into public.project_milestones(project_id, title, position)
          values (project, btrim(milestone->>'title'), next_position)
          returning id into milestone_uuid;
        next_position := next_position + 1;
        milestone_map := milestone_map || jsonb_build_object(milestone_key, milestone_uuid);
      end if;
    end if;
    next_order := next_order + 1000;
    insert into public.kanban_tasks
      (board_id, title, description, priority, status, deadline, sort_order, is_archived, milestone_id)
    values (p_board_id, btrim(draft->>'title'), btrim(draft->>'description'),
      draft->>'priority', 'todo', (draft->>'deadline')::date, next_order, false, milestone_uuid)
    returning id into task_id;
    insert into public.task_checklist_items (task_id, title, position, is_completed)
      select task_id, btrim(item.value #>> '{}'), (item.ordinality - 1)::integer, false
      from jsonb_array_elements(checklist) with ordinality item;
    insert into public.task_activity_logs (task_id, action, old_values, new_values)
      values (task_id, 'created', '{}'::jsonb, jsonb_build_object('title', draft->>'title'));
    saved := saved + 1;
  end loop;
  insert into public.kanban_write_requests (user_id, request_id, board_id, payload, saved_count)
    values (auth.uid(), p_request_id, p_board_id, versioned_payload, saved);
  return saved;
end;
$$;

revoke all on function public.save_generated_tasks_with_milestones(uuid, text, jsonb) from public;
grant execute on function public.save_generated_tasks_with_milestones(uuid, text, jsonb) to authenticated;

commit;
