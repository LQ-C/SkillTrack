-- Apply after atomic_kanban_writes.sql and project_milestones.sql.
-- Additive: one authenticated RPC, existing tables/RLS and AI RPCs unchanged.
begin;
do $prerequisites$
begin
  if to_regclass('public.project_milestones') is null
      or to_regclass('public.kanban_write_requests') is null
      or to_regprocedure('public.assert_owned_kanban_board(uuid)') is null then
    raise exception 'Apply atomic_kanban_writes.sql and project_milestones.sql first'
      using errcode = '55000';
  end if;
end;
$prerequisites$;

create or replace function public.create_project_milestone(
  p_board_id uuid, p_request_id text, p_title text
) returns setof public.project_milestones
language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  normalized_title text := regexp_replace(p_title, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  project uuid;
  next_position integer;
  created public.project_milestones;
  receipt public.kanban_write_requests;
begin
  if auth.uid() is null then
    raise exception 'Sign in to create milestones' using errcode = '42501';
  end if;
  if p_board_id is null or p_request_id is null
      or length(p_request_id) not between 16 and 128
      or normalized_title is null or length(normalized_title) not between 1 and 150 then
    raise exception 'Invalid milestone request' using errcode = '22023';
  end if;

  -- Same lock order and operation-ID namespace as the generated-task RPCs.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_request_id, 0));
  perform public.assert_owned_kanban_board(p_board_id);
  select b.project_id into project from public.kanban_boards b where b.id = p_board_id;
  -- This also serializes manual/AI milestone positions across a project's boards.
  perform p.id from public.projects p
    where p.id = project and p.owner_id = auth.uid() and p.status <> 'archived'
    for update;
  if not found then
    raise exception 'Project board unavailable' using errcode = '42501';
  end if;

  select * into receipt from public.kanban_write_requests
    where user_id = auth.uid() and request_id = p_request_id;
  if found then
    if receipt.board_id <> p_board_id
        or receipt.payload->>'format' is distinct from 'manual-milestone-v1'
        or receipt.payload->>'title' is distinct from normalized_title then
      raise exception 'Request identifier already used for another payload' using errcode = '22023';
    end if;
    select * into created from public.project_milestones m
      where m.id = (receipt.payload->>'milestone_id')::uuid and m.project_id = project;
    if not found then
      raise exception 'Saved milestone unavailable; refresh the board' using errcode = '22023';
    end if;
    return next created;
    return;
  end if;

  select coalesce(max(position), -1) + 1 into next_position
    from public.project_milestones where project_id = project;
  insert into public.project_milestones(project_id, title, position)
    values(project, normalized_title, next_position) returning * into created;
  insert into public.kanban_write_requests(user_id, request_id, board_id, payload, saved_count)
    values(auth.uid(), p_request_id, p_board_id,
      jsonb_build_object('format', 'manual-milestone-v1', 'title', normalized_title,
        'milestone_id', created.id), 1);
  return next created;
end;
$$;
revoke all on function public.create_project_milestone(uuid,text,text) from public, anon;
grant execute on function public.create_project_milestone(uuid,text,text) to authenticated;
commit;
notify pgrst, 'reload schema';
