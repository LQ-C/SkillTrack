-- Requires the existing task_tags(id uuid, owner_id uuid) and task_tag_links.
-- Does not assume a cascading FK. No table, policy or ownership changes.
begin;
create or replace function public.delete_owned_task_tag(p_tag_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  caller uuid := auth.uid();
  tag_owner uuid;
begin
  if caller is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_tag_id is null then
    raise exception 'Tag ID required' using errcode = '22004';
  end if;
  -- Lock the parent before touching links; serialize duplicate deletions and
  -- conflict with FK checks for concurrent link inserts.
  select owner_id into tag_owner from public.task_tags
    where id = p_tag_id for update;
  if not found then
    return; -- Includes retry after a committed deletion with a lost response.
  end if;
  if tag_owner is distinct from caller then
    raise exception 'Tag access denied' using errcode = '42501';
  end if;
  delete from public.task_tag_links where tag_id = p_tag_id;
  delete from public.task_tags where id = p_tag_id;
end;
$$;
revoke all on function public.delete_owned_task_tag(uuid) from public, anon;
grant execute on function public.delete_owned_task_tag(uuid) to authenticated;
notify pgrst, 'reload schema';
commit;
