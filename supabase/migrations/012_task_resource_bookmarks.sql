-- Requires existing kanban_tasks/kanban_boards/projects and learning_resources UUID IDs.
-- Marketplace SELECT policies are reused, never replaced or bypassed.
begin;
create table public.task_resource_bookmarks (
  task_id uuid not null references public.kanban_tasks(id) on delete cascade,
  resource_id uuid not null references public.learning_resources(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(task_id, resource_id)
);
create index task_resource_bookmarks_resource_idx on public.task_resource_bookmarks(resource_id);
alter table public.task_resource_bookmarks enable row level security;
-- Ownership lookup remains available for archived tasks even if task-list RLS
-- excludes them. No user ID supplied by clients; only a boolean is exposed.
create function public.owns_bookmark_task(p_task_id uuid, p_writable boolean default false)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.kanban_tasks t
    join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
    where t.id=p_task_id and p.owner_id=auth.uid()
      and (not p_writable or (p.status='active' and not b.is_archived and not t.is_archived and t.status<>'completed')))
$$;
revoke all on function public.owns_bookmark_task(uuid,boolean) from public,anon;
grant execute on function public.owns_bookmark_task(uuid,boolean) to authenticated;
create policy bookmark_read on public.task_resource_bookmarks for select to authenticated
  using(public.owns_bookmark_task(task_id));
create policy bookmark_add on public.task_resource_bookmarks for insert to authenticated
  with check(public.owns_bookmark_task(task_id,true) and exists(
    select 1 from public.learning_resources r where r.id=resource_id
      and r.status='published' and not r.moderation_hidden));
create policy bookmark_remove on public.task_resource_bookmarks for delete to authenticated
  using(public.owns_bookmark_task(task_id));
revoke all on public.task_resource_bookmarks from public,anon,authenticated;
grant select,insert,delete on public.task_resource_bookmarks to authenticated;
create function public.set_task_resource_bookmark(p_task_id uuid,p_resource_id uuid,p_saved boolean)
returns void language plpgsql security invoker set search_path='' as $$
begin
  if auth.uid() is null or not public.owns_bookmark_task(p_task_id) then
    raise exception 'Task access denied' using errcode='42501';
  end if;
  if p_saved is null or p_resource_id is null then raise exception 'Invalid bookmark' using errcode='22023'; end if;
  if p_saved then
    -- Existing saved pair is an idempotent success, even if access/status has
    -- changed since a lost response. No new content is exposed by this call.
    if exists(select 1 from public.task_resource_bookmarks where task_id=p_task_id and resource_id=p_resource_id) then return; end if;
    insert into public.task_resource_bookmarks(task_id,resource_id) values(p_task_id,p_resource_id)
      on conflict(task_id,resource_id) do nothing;
  else
    delete from public.task_resource_bookmarks where task_id=p_task_id and resource_id=p_resource_id;
  end if;
end $$;
create function public.task_saved_resources(p_task_id uuid)
returns table(resource_id uuid,title text,summary text,type text)
language plpgsql stable security invoker set search_path='' as $$
begin
  if auth.uid() is null or not public.owns_bookmark_task(p_task_id) then
    raise exception 'Task access denied' using errcode='42501';
  end if;
  return query select saved.resource_id,
    coalesce(r.title,'Resource unavailable')::text,coalesce(r.summary,'')::text,coalesce(r.kind,'')::text
    from public.task_resource_bookmarks saved
    left join public.learning_resources r on r.id=saved.resource_id and r.status='published' and not r.moderation_hidden
    where saved.task_id=p_task_id order by saved.created_at,saved.resource_id;
end $$;
revoke all on function public.set_task_resource_bookmark(uuid,uuid,boolean) from public,anon;
revoke all on function public.task_saved_resources(uuid) from public,anon;
grant execute on function public.set_task_resource_bookmark(uuid,uuid,boolean),public.task_saved_resources(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
