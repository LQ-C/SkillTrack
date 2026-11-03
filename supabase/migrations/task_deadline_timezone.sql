-- Run after atomic_kanban_writes.sql, project_milestones.sql and the notification
-- migrations. Existing deadline instants and legacy classification stay unchanged.
-- No table, RLS, timer, stagnation formula, webhook or cron changes.
begin;
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public'
    and table_name='kanban_tasks' and column_name='deadline' and udt_name='timestamptz') then
    raise exception 'Timezone repair requires kanban_tasks.deadline timestamptz';
  end if;
  if to_regclass('public.kanban_write_requests') is null
    or to_regprocedure('public.save_generated_tasks(uuid,text,jsonb)') is null
    or to_regprocedure('public.save_generated_tasks_with_milestones(uuid,text,jsonb)') is null then
    raise exception 'Apply atomic_kanban_writes.sql and project_milestones.sql first';
  end if;
end;
$$;

-- NULL: legacy/unknown; false: date-only; true: explicit time, including midnight.
-- Do not backfill by guessing from a midnight timestamp.
alter table public.kanban_tasks add column if not exists deadline_has_time boolean;

create or replace function public.save_generated_tasks(
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
    if receipt.board_id <> p_board_id or receipt.payload <> p_tasks then
      raise exception 'Request identifier already used for another payload' using errcode = '22023';
    end if;
    return receipt.saved_count;
  end if;
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
    normalized_title := regexp_replace(lower(btrim(draft->>'title')), '[^[:alnum:]]+', ' ', 'g');
    if exists (select 1 from public.kanban_tasks t where t.board_id = p_board_id
      and regexp_replace(lower(btrim(t.title)), '[^[:alnum:]]+', ' ', 'g') = normalized_title) then
      continue;
    end if;
    next_order := next_order + 1000;
    insert into public.kanban_tasks
      (board_id, title, description, priority, status, deadline, deadline_has_time, sort_order, is_archived)
    values (p_board_id, btrim(draft->>'title'), btrim(draft->>'description'),
      draft->>'priority', 'todo', (((draft->>'deadline')::date + 1)::timestamp at time zone 'Asia/Kuala_Lumpur') - interval '1 millisecond', false, next_order, false)
    returning id into task_id;
    insert into public.task_checklist_items (task_id, title, position, is_completed)
      select task_id, btrim(item.value #>> '{}'), (item.ordinality - 1)::integer, false
      from jsonb_array_elements(checklist) with ordinality item;
    insert into public.task_activity_logs (task_id, action, old_values, new_values)
      values (task_id, 'created', '{}'::jsonb, jsonb_build_object('title', draft->>'title'));
    saved := saved + 1;
  end loop;
  insert into public.kanban_write_requests (user_id, request_id, board_id, payload, saved_count)
    values (auth.uid(), p_request_id, p_board_id, p_tasks, saved);
  return saved;
end;
$$;

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
      (board_id, title, description, priority, status, deadline, deadline_has_time, sort_order, is_archived, milestone_id)
    values (p_board_id, btrim(draft->>'title'), btrim(draft->>'description'),
      draft->>'priority', 'todo', (((draft->>'deadline')::date + 1)::timestamp at time zone 'Asia/Kuala_Lumpur') - interval '1 millisecond', false, next_order, false, milestone_uuid)
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


-- Extend the candidate contract without deleting dependent objects via CASCADE.
drop function if exists public.notification_task_candidates(integer, integer);
create function public.notification_task_candidates(
  p_offset integer, p_limit integer)
returns table (
  task_id uuid, board_id uuid, project_id uuid, user_id uuid,
  task_title text, task_status text, task_archived boolean,
  board_archived boolean, project_status text, profile_exists boolean,
  deadline text, last_activity_at text, task_created_at text, deadline_has_time boolean)
language sql stable security invoker
set search_path = public, pg_temp set timezone = 'UTC' as $$
  select t.id, b.id, p.id, p.owner_id, t.title::text, t.status::text,
    coalesce(t.is_archived, false), coalesce(b.is_archived, false),
    p.status::text, pr.id is not null, t.deadline::text,
    coalesce(activity.created_at, t.updated_at, t.created_at)::text, t.created_at::text, t.deadline_has_time
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



revoke all on function public.notification_task_candidates(integer,integer) from public,anon,authenticated;
grant execute on function public.notification_task_candidates(integer,integer) to service_role;
revoke all on function public.save_generated_tasks(uuid,text,jsonb) from public,anon;
revoke all on function public.save_generated_tasks_with_milestones(uuid,text,jsonb) from public,anon;
grant execute on function public.save_generated_tasks(uuid,text,jsonb) to authenticated;
grant execute on function public.save_generated_tasks_with_milestones(uuid,text,jsonb) to authenticated;
commit;
