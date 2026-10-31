-- Additive repair: uses the existing Kanban tables and their RLS policies.
-- Each RPC is one transaction. No elevated ownership bypass is used.
create table public.kanban_write_requests (
  user_id uuid not null references auth.users(id) on delete cascade,
  request_id text not null check (length(request_id) between 16 and 128),
  board_id uuid not null references public.kanban_boards(id) on delete cascade,
  payload jsonb not null,
  saved_count integer not null,
  created_at timestamptz not null default now(),
  primary key (user_id, request_id)
);
alter table public.kanban_write_requests enable row level security;
create policy kanban_write_requests_select on public.kanban_write_requests
  for select to authenticated using (user_id = auth.uid());
create policy kanban_write_requests_insert on public.kanban_write_requests
  for insert to authenticated with check (user_id = auth.uid());
revoke all on public.kanban_write_requests from anon, authenticated;
grant select, insert on public.kanban_write_requests to authenticated;

create function public.assert_owned_kanban_board(p_board_id uuid)
returns void language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  perform b.id from public.kanban_boards b
    join public.projects p on p.id = b.project_id
    where b.id = p_board_id and p.owner_id = auth.uid()
      and not b.is_archived and p.status <> 'archived'
    for update of b;
  if not found then raise exception 'Project board unavailable' using errcode = '42501'; end if;
end;
$$;

create function public.save_generated_tasks(
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
      (board_id, title, description, priority, status, deadline, sort_order, is_archived)
    values (p_board_id, btrim(draft->>'title'), btrim(draft->>'description'),
      draft->>'priority', 'todo', (draft->>'deadline')::date, next_order, false)
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

create function public.reorder_kanban_tasks(p_tasks jsonb)
returns void language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_board_id uuid; expected integer; matched integer;
begin
  if jsonb_typeof(p_tasks) is distinct from 'array' then raise exception 'Invalid task order'; end if;
  expected := jsonb_array_length(p_tasks);
  if expected = 0 then return; end if;
  select t.board_id into v_board_id from public.kanban_tasks t
    where t.id = (p_tasks->0->>'id')::uuid;
  perform public.assert_owned_kanban_board(v_board_id);
  select count(distinct t.id) into matched
    from public.kanban_tasks t join jsonb_to_recordset(p_tasks) x(id uuid, sort_order bigint)
      on x.id = t.id where t.board_id = v_board_id and x.sort_order is not null;
  if matched <> expected then raise exception 'Invalid task order'; end if;
  update public.kanban_tasks t set sort_order = x.sort_order
    from jsonb_to_recordset(p_tasks) x(id uuid, sort_order bigint) where x.id = t.id;
end;
$$;

create function public.reorder_task_checklist(p_task_id uuid, p_items jsonb)
returns void language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_board_id uuid; expected integer; matched integer;
begin
  select t.board_id into v_board_id from public.kanban_tasks t where t.id = p_task_id;
  perform public.assert_owned_kanban_board(v_board_id);
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Invalid checklist order'; end if;
  expected := jsonb_array_length(p_items);
  select count(distinct c.id) into matched from public.task_checklist_items c
    join jsonb_to_recordset(p_items) x(id uuid, position integer) on x.id = c.id
    where c.task_id = p_task_id and x.position >= 0;
  if matched <> expected or (select count(distinct x.position)
    from jsonb_to_recordset(p_items) x(position integer)) <> expected then
    raise exception 'Invalid checklist order';
  end if;
  update public.task_checklist_items c set position = x.position
    from jsonb_to_recordset(p_items) x(id uuid, position integer) where x.id = c.id;
  insert into public.task_activity_logs (task_id, action, old_values, new_values)
    values (p_task_id, 'checklist_updated', '{}'::jsonb, '{"change":"reordered"}'::jsonb);
end;
$$;

create function public.delete_task_checklist_item(p_item_id uuid)
returns void language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_task_id uuid; v_board_id uuid;
begin
  select c.task_id, t.board_id into v_task_id, v_board_id
    from public.task_checklist_items c join public.kanban_tasks t on t.id = c.task_id
    where c.id = p_item_id;
  perform public.assert_owned_kanban_board(v_board_id);
  delete from public.task_checklist_items where id = p_item_id;
  insert into public.task_activity_logs (task_id, action, old_values, new_values)
    values (v_task_id, 'checklist_updated', '{}'::jsonb, '{"change":"removed"}'::jsonb);
end;
$$;

create function public.register_task_attachment(
  p_task_id uuid, p_file_name text, p_storage_path text, p_mime_type text, p_file_size bigint
) returns public.task_attachments
language plpgsql security invoker set search_path = public, pg_temp as $$
declare v_board_id uuid; attachment public.task_attachments;
begin
  select t.board_id into v_board_id from public.kanban_tasks t where t.id = p_task_id;
  perform public.assert_owned_kanban_board(v_board_id);
  if p_storage_path is null or p_file_size is null or p_file_name is null
      or length(btrim(p_file_name)) not between 1 and 255
      or p_storage_path not like auth.uid()::text || '/' || p_task_id::text || '/%'
      or p_file_size not between 1 and 10485760 then raise exception 'Invalid attachment'; end if;
  insert into public.task_attachments (task_id, file_name, storage_path, mime_type, file_size_bytes)
    values (p_task_id, p_file_name, p_storage_path, p_mime_type, p_file_size)
    returning * into attachment;
  insert into public.task_activity_logs (task_id, action, old_values, new_values)
    values (p_task_id, 'attachment_added', '{}'::jsonb, jsonb_build_object('file_name', p_file_name));
  return attachment;
end;
$$;

revoke all on function public.assert_owned_kanban_board(uuid) from public;
revoke all on function public.save_generated_tasks(uuid, text, jsonb) from public;
revoke all on function public.reorder_kanban_tasks(jsonb) from public;
revoke all on function public.reorder_task_checklist(uuid, jsonb) from public;
revoke all on function public.delete_task_checklist_item(uuid) from public;
revoke all on function public.register_task_attachment(uuid, text, text, text, bigint) from public;
grant execute on function public.assert_owned_kanban_board(uuid),
  public.save_generated_tasks(uuid, text, jsonb),
  public.reorder_kanban_tasks(jsonb), public.reorder_task_checklist(uuid, jsonb),
  public.delete_task_checklist_item(uuid),
  public.register_task_attachment(uuid, text, text, text, bigint) to authenticated;
