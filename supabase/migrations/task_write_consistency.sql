-- Apply after atomic_kanban_writes, task_time_tracking, task_deadline_timezone
-- and the task activity/milestone migrations.
begin;

create or replace function public.save_kanban_task_edit(
  p_task_id uuid, p_expected_updated_at timestamptz, p_request_id text,
  p_changes jsonb, p_add_tag_ids uuid[], p_remove_tag_ids uuid[]
) returns jsonb language plpgsql security invoker
set search_path = public, pg_temp set timezone = 'UTC' as $$
declare
  owner uuid := auth.uid();
  board uuid;
  previous public.kanban_tasks;
  changes public.kanban_tasks;
  receipt public.kanban_write_requests;
  payload jsonb := jsonb_build_object('format', 'task-edit-v1', 'task_id', p_task_id,
    'expected_updated_at', p_expected_updated_at, 'changes', p_changes,
    'add_tag_ids', p_add_tag_ids, 'remove_tag_ids', p_remove_tag_ids);
  destination_order bigint;
begin
  if owner is null then
    raise exception 'Sign in to edit tasks' using errcode = '42501';
  end if;
  if p_request_id is null or length(p_request_id) not between 16 and 128
      or p_expected_updated_at is null
      or p_add_tag_ids is null or p_remove_tag_ids is null
      or p_add_tag_ids && p_remove_tag_ids
      or jsonb_typeof(p_changes) is distinct from 'object'
      or not (p_changes ?& array['title','description','status','priority','deadline','deadline_has_time','milestone_id'])
      or coalesce(p_changes->>'status', '') not in ('todo','in_progress','completed')
      or coalesce(p_changes->>'priority', '') not in ('low','medium','high')
      or coalesce(btrim(p_changes->>'title'), '') = '' then
    raise exception 'Invalid task edit' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(owner::text || p_request_id, 0));
  select t.board_id into board from public.kanban_tasks t where t.id = p_task_id;
  perform public.assert_owned_kanban_board(board);
  select * into previous from public.kanban_tasks t
    where t.id = p_task_id and t.board_id = board and not coalesce(t.is_archived, false)
    for update;
  if not found then raise exception 'Task unavailable' using errcode = '42501'; end if;

  select * into receipt from public.kanban_write_requests
    where user_id = owner and request_id = p_request_id;
  if found then
    if receipt.board_id <> board or receipt.payload <> payload then
      raise exception 'Request identifier already used for another payload' using errcode = '22023';
    end if;
  else
    if previous.updated_at is distinct from p_expected_updated_at then
      raise exception 'Task changed. Refresh it and try again.' using errcode = '40001';
    end if;
    changes := jsonb_populate_record(null::public.kanban_tasks, p_changes);
    if exists (
      select 1 from unnest(p_add_tag_ids) as requested(id)
      left join public.task_tags tag on tag.id = requested.id and tag.owner_id = owner
      where tag.id is null
    ) then
      raise exception 'Tag unavailable' using errcode = '42501';
    end if;

    if previous.status is distinct from changes.status then
      select coalesce(max(t.sort_order), 0) + 1000 into destination_order
        from public.kanban_tasks t where t.board_id = board and not coalesce(t.is_archived, false)
        and t.status = changes.status;
      perform public.update_kanban_task_tracking(
        p_task_id, 'move', p_expected_updated_at, changes.status::text, destination_order
      );
    end if;

    update public.kanban_tasks set title = btrim(changes.title), description = changes.description,
      priority = changes.priority, deadline = changes.deadline,
      deadline_has_time = case when changes.deadline is not null then changes.deadline_has_time end,
      milestone_id = changes.milestone_id, updated_at = clock_timestamp()
      where id = p_task_id;

    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      values (p_task_id, 'updated', '{}'::jsonb, jsonb_build_object('title', btrim(changes.title)));
    if previous.status is distinct from changes.status then
      insert into public.task_activity_logs(task_id, action, old_values, new_values)
        values (p_task_id, case when changes.status = 'completed' then 'completed'
          when previous.status = 'completed' then 'reopened' else 'moved' end,
          jsonb_build_object('status', previous.status), jsonb_build_object('status', changes.status));
    end if;

    with removed as (
      delete from public.task_tag_links
      where task_id = p_task_id and tag_id = any(p_remove_tag_ids) returning tag_id
    )
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      select p_task_id, 'tag_removed', jsonb_build_object('tag_id', tag_id), '{}'::jsonb
      from removed;

    with added as (
      insert into public.task_tag_links(task_id, tag_id)
      select p_task_id, id from unnest(p_add_tag_ids) as requested(id)
      on conflict (task_id, tag_id) do nothing returning tag_id
    )
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      select p_task_id, 'tag_added', '{}'::jsonb, jsonb_build_object('tag_id', tag_id)
      from added;

    insert into public.kanban_write_requests(user_id, request_id, board_id, payload, saved_count)
      values (owner, p_request_id, board, payload, 1);
  end if;

  -- Read after activity triggers, which may have updated the stalled state.
  return (select jsonb_build_object(
    'task', to_jsonb(t),
    'tags', coalesce((select jsonb_agg(to_jsonb(tag) order by tag.id)
      from public.task_tag_links link join public.task_tags tag on tag.id = link.tag_id
      where link.task_id = t.id), '[]'::jsonb),
    'checklist', coalesce((select jsonb_agg(to_jsonb(i) order by i.position, i.id)
      from public.task_checklist_items i where i.task_id = t.id), '[]'::jsonb),
    'attachments', coalesce((select jsonb_agg(to_jsonb(a) order by a.id)
      from public.task_attachments a where a.task_id = t.id), '[]'::jsonb))
    from public.kanban_tasks t where t.id = p_task_id);
end;
$$;

revoke all on function public.save_kanban_task_edit(uuid,timestamptz,text,jsonb,uuid[],uuid[]) from public, anon;
grant execute on function public.save_kanban_task_edit(uuid,timestamptz,text,jsonb,uuid[],uuid[]) to authenticated;

create table if not exists public.task_attachment_cleanup (
  user_id uuid not null references auth.users(id) on delete cascade,
  storage_path text not null check (split_part(storage_path, '/', 1) = user_id::text),
  created_at timestamptz not null default now(),
  primary key (user_id, storage_path)
);
alter table public.task_attachment_cleanup enable row level security;
revoke all on public.task_attachment_cleanup from public, anon, authenticated;
grant select, insert, delete on public.task_attachment_cleanup to authenticated;
drop policy if exists own_attachment_cleanup on public.task_attachment_cleanup;
create policy own_attachment_cleanup on public.task_attachment_cleanup to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.queue_deleted_task_attachment()
returns trigger language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  -- Queue only files the signed-in owner can remove via the Storage API.
  if split_part(old.storage_path, '/', 1) = auth.uid()::text
      and not exists (select 1 from public.task_attachments a where a.storage_path = old.storage_path) then
    insert into public.task_attachment_cleanup(user_id, storage_path)
      values (auth.uid(), old.storage_path) on conflict do nothing;
  end if;
  return old;
end;
$$;
revoke all on function public.queue_deleted_task_attachment() from public, anon, authenticated;
drop trigger if exists queue_deleted_task_attachment on public.task_attachments;
create trigger queue_deleted_task_attachment after delete on public.task_attachments
  for each row execute function public.queue_deleted_task_attachment();

create or replace function public.delete_kanban_task_attachment(p_attachment_id uuid)
returns void language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  attachment public.task_attachments;
  board uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in to delete attachments' using errcode = '42501';
  end if;
  select a.* into attachment from public.task_attachments a where a.id = p_attachment_id;
  if not found then return; end if;
  select t.board_id into board from public.kanban_tasks t where t.id = attachment.task_id;
  perform public.assert_owned_kanban_board(board);
  perform t.id from public.kanban_tasks t where t.id = attachment.task_id
    and not coalesce(t.is_archived, false) for update;
  if not found then raise exception 'Task unavailable' using errcode = '42501'; end if;
  delete from public.task_attachments where id = p_attachment_id returning * into attachment;
  if found then
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      values (attachment.task_id, 'attachment_removed', jsonb_build_object('file_name', attachment.file_name), '{}'::jsonb);
  end if;
end;
$$;
revoke all on function public.delete_kanban_task_attachment(uuid) from public, anon;
grant execute on function public.delete_kanban_task_attachment(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
