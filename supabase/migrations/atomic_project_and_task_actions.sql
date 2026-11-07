-- Apply after task_generated_deadline_malaysia.sql, task_time_tracking.sql,
-- task_meaningful_progress.sql and task_write_consistency.sql. Requires the
-- existing project, board, task and attachment schema and projects.constraints_text.
begin;

do $prerequisites$
begin
  if not exists (select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'projects' and column_name = 'constraints_text')
    or to_regclass('public.kanban_write_requests') is null
    or to_regprocedure('public.save_generated_tasks_with_milestones(uuid,text,jsonb)') is null
    or to_regprocedure('public.update_kanban_task_tracking(uuid,text,timestamptz,text,bigint)') is null
    or to_regprocedure('public.save_kanban_task_edit(uuid,timestamptz,text,jsonb,uuid[],uuid[])') is null then
    raise exception 'Install the SkillTrack base schema and project/task prerequisites first'
      using errcode = '55000';
  end if;
end;
$prerequisites$;

-- Legacy receipts keep their board foreign key and cascade behavior. New
-- receipts keep the board ID in the payload, so deleting a board cannot erase
-- the evidence of a successful request and allow it to run again.
alter table public.kanban_write_requests alter column board_id drop not null;
alter table public.kanban_write_requests
  drop constraint if exists kanban_write_requests_receipt_scope_check;
alter table public.kanban_write_requests
  add constraint kanban_write_requests_receipt_scope_check check (
    (board_id is null) = (request_id like 'skilltrack:v1:%')
  );

drop policy if exists kanban_write_requests_check_durable_board on public.kanban_write_requests;
create policy kanban_write_requests_check_durable_board on public.kanban_write_requests
  as restrictive for insert to authenticated with check (
    board_id is not null or request_id like 'skilltrack:v1:attachment_cleanup:%' or exists (
    select 1 from public.kanban_boards b join public.projects p on p.id = b.project_id
      where b.id = (kanban_write_requests.payload->>'board_id')::uuid
        and p.owner_id = auth.uid()
  ));

create or replace function public.skilltrack_receipt_key(p_operation text, p_request_id text)
returns text language sql immutable strict set search_path = pg_catalog as $$
  select 'skilltrack:v1:' || p_operation || ':' || encode(sha256(convert_to(p_request_id, 'UTF8')), 'hex');
$$;

-- If the previous draft already ran, preserve its receipts without changing its table.
do $upgrade$
begin
  if to_regclass('public.skilltrack_write_receipts') is not null then
    insert into public.kanban_write_requests(user_id, request_id, board_id, payload, saved_count)
      select user_id, public.skilltrack_receipt_key(operation, request_id), null,
        jsonb_build_object('request_id', request_id, 'board_id', board_id, 'request', payload, 'result', result),
        coalesce((result->>'total_task_count')::integer, 1)
      from public.skilltrack_write_receipts
      on conflict (user_id, request_id) do nothing;
  end if;
end;
$upgrade$;

-- The caller's transaction holds the lock until its writes and receipt commit.
create or replace function public.replay_skilltrack_write(
  p_operation text, p_request_id text, p_payload jsonb
) returns jsonb language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  owner uuid := auth.uid();
  receipt public.kanban_write_requests;
  receipt_key text := public.skilltrack_receipt_key(p_operation, p_request_id);
begin
  if owner is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_request_id is null or length(p_request_id) not between 16 and 128
      or p_operation is null or p_operation not in
        ('create_project', 'confirm_plan', 'create_task', 'move', 'archive', 'restore', 'resume') then
    raise exception 'Invalid request identifier' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(owner::text || ':' || receipt_key, 0));
  select * into receipt from public.kanban_write_requests
    where user_id = owner and request_id = receipt_key;
  if not found then return null; end if;
  if receipt.payload->>'request_id' is distinct from p_request_id
      or receipt.payload->'request' is distinct from p_payload then
    raise exception 'Request identifier already used for another payload' using errcode = '22023';
  end if;
  perform b.id from public.kanban_boards b join public.projects p on p.id = b.project_id
    where b.id = (receipt.payload->>'board_id')::uuid and p.owner_id = owner for update of b;
  if not found then raise exception 'Project board unavailable' using errcode = '42501'; end if;
  return receipt.payload->'result';
end;
$$;

create or replace function public.save_new_skilltrack_project(
  p_request_id text, p_name text, p_description text, p_constraints text,
  p_start_date date, p_end_date date, p_tasks jsonb
) returns jsonb language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  owner uuid := auth.uid();
  project public.projects;
  board uuid;
  normalized_constraints text := nullif(btrim(p_constraints), '');
  operation text := case when p_tasks is null then 'create_project' else 'confirm_plan' end;
  payload jsonb := jsonb_build_object('name', p_name, 'description', p_description,
    'constraints', p_constraints, 'start_date', p_start_date, 'end_date', p_end_date, 'tasks', p_tasks);
  result jsonb;
  saved integer := 0;
begin
  result := public.replay_skilltrack_write(operation, p_request_id, payload);
  if result is not null then return result; end if;

  if coalesce(length(btrim(p_name)), 0) not between 1 and 150
      or length(normalized_constraints) > 1000
      or p_start_date > p_end_date then
    raise exception 'Invalid project fields' using errcode = '22023';
  end if;
  if p_tasks is not null and (jsonb_typeof(p_tasks) is distinct from 'array'
      or p_start_date is null or p_end_date is null
      or coalesce(length(btrim(p_description)), 0) not between 1 and 4000) then
    raise exception 'Invalid generated project' using errcode = '22023';
  end if;

  begin
    insert into public.projects(owner_id, name, description, constraints_text, status, start_date, end_date)
      values (owner, btrim(p_name), nullif(btrim(p_description), ''), normalized_constraints,
        'active', p_start_date, p_end_date) returning * into project;
    insert into public.kanban_boards(project_id, name)
      values (project.id, 'Kanban Board') returning id into board;
  exception when others then
    raise exception using errcode = SQLSTATE, message = SQLERRM, hint = 'skilltrack_project_setup';
  end;

  if p_tasks is not null then
    if exists (select 1 from jsonb_array_elements(p_tasks) d
      where jsonb_typeof(d->'milestone') = 'object') then
      saved := public.save_generated_tasks_with_milestones(board, gen_random_uuid()::text, p_tasks);
    else
      saved := public.save_generated_tasks(board, gen_random_uuid()::text, p_tasks);
    end if;
    -- A newly created board has no existing tasks. A partial batch is invalid.
    if saved <> jsonb_array_length(p_tasks) then
      raise exception 'Generated plan contains duplicate tasks' using errcode = '22023';
    end if;
  end if;

  result := jsonb_build_object('project', to_jsonb(project), 'board_id', board, 'total_task_count', saved);
  insert into public.kanban_write_requests(user_id, request_id, board_id, payload, saved_count)
    values (owner, public.skilltrack_receipt_key(operation, p_request_id), null,
      jsonb_build_object('request_id', p_request_id, 'board_id', board, 'request', payload, 'result', result), saved);
  return result;
end;
$$;

create or replace function public.save_skilltrack_task_action(
  p_board_id uuid, p_operation text, p_request_id text, p_payload jsonb
) returns jsonb language plpgsql security invoker
set search_path = public, pg_temp set timezone = 'UTC' as $$
declare
  owner uuid := auth.uid();
  payload jsonb := jsonb_build_object('board_id', p_board_id, 'fields', p_payload);
  result jsonb;
  previous public.kanban_tasks;
  fields public.kanban_tasks;
  task_id_value uuid;
  now_at timestamptz;
  tag_ids uuid[];
  column_ids uuid[];
  column_orders bigint[];
  target_index integer;
  old_index integer;
  destination_order bigint;
  activity_action public.task_activity_logs.action%type;
begin
  if p_operation is null or p_operation not in ('create_task','move','archive','restore','resume')
      or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'Invalid task action' using errcode = '22023';
  end if;
  result := public.replay_skilltrack_write(p_operation, p_request_id, payload);
  if result is not null then return result; end if;

  if p_operation in ('archive', 'restore') then
    perform b.id from public.kanban_boards b join public.projects p on p.id = b.project_id
      where b.id = p_board_id and p.owner_id = owner for update of b;
    if not found then raise exception 'Project board unavailable' using errcode = '42501'; end if;
  else
    perform public.assert_owned_kanban_board(p_board_id);
  end if;

  if p_operation = 'create_task' then
    fields := jsonb_populate_record(null::public.kanban_tasks, p_payload);
    if coalesce(btrim(fields.title), '') = '' or fields.status is null
        or fields.status::text not in ('todo', 'in_progress', 'completed')
        or fields.priority is null or fields.priority::text not in ('low', 'medium', 'high')
        or jsonb_typeof(p_payload->'tag_ids') is distinct from 'array'
        or jsonb_typeof(p_payload->'checklist') is distinct from 'array'
        or exists (select 1 from jsonb_array_elements(p_payload->'checklist') e
          where jsonb_typeof(e) is distinct from 'string') then
      raise exception 'Invalid task fields' using errcode = '22023';
    end if;
    tag_ids := array(select distinct value::uuid from jsonb_array_elements_text(p_payload->'tag_ids'));
    if exists (select 1 from unnest(tag_ids) x(id)
      left join public.task_tags t on t.id = x.id and t.owner_id = owner where t.id is null) then
      raise exception 'Tag unavailable' using errcode = '42501';
    end if;
    select coalesce(max(t.sort_order), 0) + 1000 into destination_order from public.kanban_tasks t
      where t.board_id = p_board_id and t.status = fields.status and not coalesce(t.is_archived, false);
    now_at := clock_timestamp();
    insert into public.kanban_tasks(board_id, title, description, status, priority,
      deadline, deadline_has_time, milestone_id, sort_order, is_archived, completed_at,
      elapsed_seconds, tracking_started_at, created_at, updated_at)
    values (p_board_id, btrim(fields.title), coalesce(fields.description, ''), fields.status, fields.priority,
      fields.deadline, case when fields.deadline is not null then fields.deadline_has_time end,
      fields.milestone_id, destination_order, false, case when fields.status::text = 'completed' then now_at end,
      0, case when fields.status::text = 'in_progress' then now_at end, now_at, now_at)
    returning id into task_id_value;

    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      values (task_id_value, 'created', '{}'::jsonb, jsonb_build_object('title', btrim(fields.title)));
    insert into public.task_tag_links(task_id, tag_id) select task_id_value, id from unnest(tag_ids) x(id);
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      select task_id_value, 'tag_added', '{}'::jsonb, jsonb_build_object('tag_id', id) from unnest(tag_ids) x(id);
    with added as (
      insert into public.task_checklist_items(task_id, title, position, is_completed)
        select task_id_value, btrim(value), (ordinality - 1)::integer, false
        from jsonb_array_elements_text(p_payload->'checklist') with ordinality where btrim(value) <> ''
        returning id
    )
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      select task_id_value, 'checklist_updated', '{}'::jsonb, '{}'::jsonb from added;
  else
    task_id_value := (p_payload->>'task_id')::uuid;
    select * into previous from public.kanban_tasks t
      where t.id = task_id_value and t.board_id = p_board_id for update;
    if not found or (p_operation in ('move', 'resume') and coalesce(previous.is_archived, false)) then
      raise exception 'Task unavailable' using errcode = '42501';
    end if;
    if previous.updated_at is distinct from (p_payload->>'expected_updated_at')::timestamptz
        or (p_operation = 'move' and previous.sort_order is distinct from (p_payload->>'expected_sort_order')::bigint) then
      raise exception 'Task changed. Refresh it and try again.' using errcode = '40001';
    end if;

    if p_operation = 'move' then
      fields := jsonb_populate_record(null::public.kanban_tasks, p_payload);
      if fields.status is null or fields.status::text not in ('todo','in_progress','completed') then
        raise exception 'Invalid destination status' using errcode = '22023';
      end if;
      select array_agg(t.id order by t.sort_order, t.id), array_agg(t.sort_order order by t.sort_order, t.id)
        into column_ids, column_orders from public.kanban_tasks t
        where t.board_id = p_board_id and t.status = fields.status and t.id <> task_id_value
          and not coalesce(t.is_archived, false);
      target_index := least(greatest(coalesce((p_payload->>'new_index')::integer, cardinality(column_ids), 0), 0),
        coalesce(cardinality(column_ids), 0));
      select count(*) into old_index from public.kanban_tasks t
        where t.board_id = p_board_id and t.status = previous.status and not coalesce(t.is_archived, false)
        and (t.sort_order, t.id) < (previous.sort_order, previous.id);

      if previous.status is distinct from fields.status or old_index <> target_index then
        destination_order := case
          when coalesce(cardinality(column_ids), 0) = 0 then 1000
          when target_index = 0 and column_orders[1] > 1 then column_orders[1] / 2
          when target_index = cardinality(column_ids) then column_orders[target_index] + 1000
          when column_orders[target_index + 1] - column_orders[target_index] > 1
            then column_orders[target_index] + (column_orders[target_index + 1] - column_orders[target_index]) / 2
        end;
        if destination_order is null then
          destination_order := (target_index + 1) * 1000::bigint;
          update public.kanban_tasks t
            set sort_order = (x.ordinality + case when x.ordinality > target_index then 1 else 0 end) * 1000,
                updated_at = clock_timestamp()
            from unnest(column_ids) with ordinality x(id, ordinality)
            where t.id = x.id;
        end if;
        perform public.update_kanban_task_tracking(task_id_value, 'move', previous.updated_at,
          fields.status::text, destination_order);
        if previous.status is distinct from fields.status then
          activity_action := case when fields.status::text = 'completed' then 'completed'
            when previous.status::text = 'completed' then 'reopened' else 'moved' end;
          insert into public.task_activity_logs(task_id, action, old_values, new_values)
            values (task_id_value, activity_action,
              jsonb_build_object('status', previous.status, 'position', old_index),
              jsonb_build_object('status', fields.status, 'position', target_index));
        end if;
      end if;
    elsif p_operation = 'resume' then
      if previous.is_stalled then
        update public.kanban_tasks set is_stalled = false, stagnation_score = 0,
          stalled_at = null, updated_at = clock_timestamp() where id = task_id_value;
        insert into public.task_activity_logs(task_id, action, old_values, new_values)
          values (task_id_value, 'resumed', '{}'::jsonb, '{}'::jsonb);
      end if;
    elsif coalesce(previous.is_archived, false) <> (p_operation = 'archive') then
      now_at := clock_timestamp();
      -- Archiving settles an active session. Restoring leaves the timer paused.
      update public.kanban_tasks set is_archived = (p_operation = 'archive'), updated_at = now_at,
        elapsed_seconds = elapsed_seconds + case
          when p_operation = 'archive' and tracking_started_at is not null
          then greatest(0::bigint, floor(extract(epoch from (now_at - tracking_started_at)))::bigint)
          else 0 end,
        tracking_started_at = case when p_operation = 'archive' then null else tracking_started_at end
        where id = task_id_value;
      activity_action := case when p_operation = 'archive' then 'archived' else 'restored' end;
      insert into public.task_activity_logs(task_id, action, old_values, new_values)
        values (task_id_value, activity_action, '{}'::jsonb, '{}'::jsonb);
    end if;
  end if;

  select jsonb_build_object('task', to_jsonb(t)) into result
    from public.kanban_tasks t where t.id = task_id_value;
  insert into public.kanban_write_requests(user_id, request_id, board_id, payload, saved_count)
    values (owner, public.skilltrack_receipt_key(p_operation, p_request_id), null,
      jsonb_build_object('request_id', p_request_id, 'board_id', p_board_id, 'request', payload, 'result', result), 1);
  return result;
end;
$$;

revoke all on function public.skilltrack_receipt_key(text,text),
  public.replay_skilltrack_write(text,text,jsonb),
  public.save_new_skilltrack_project(text,text,text,text,date,date,jsonb),
  public.save_skilltrack_task_action(uuid,text,text,jsonb) from public, anon;
grant execute on function public.skilltrack_receipt_key(text,text),
  public.replay_skilltrack_write(text,text,jsonb),
  public.save_new_skilltrack_project(text,text,text,text,date,date,jsonb),
  public.save_skilltrack_task_action(uuid,text,text,jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
