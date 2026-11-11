-- Requires semantic migrations 009/010 and the existing notification migrations.
-- No new tables, policies, notification types or push transport.
begin;
do $$ begin
  if exists(select 1 from pg_roles where rolname='authenticated' and (rolsuper or rolbypassrls))
    or (select relowner from pg_class where oid='public.learning_resources'::regclass) = 'authenticated'::regrole then
    raise exception 'Authenticated marketplace reader must not bypass RLS';
  end if;
end $$;

-- Execute this small reader as the authenticated role so actual marketplace RLS
-- is evaluated, rather than bypassed by the scheduler's service role. It accepts
-- no recipient argument: direct callers can only read their own JWT context.
create function public.recommendation_rls_resources(p_ids uuid[] default null)
returns table(id uuid,title text,summary text,kind text,updated_at timestamptz)
language sql stable security definer set search_path='' set row_security=on as $$
  select r.id,r.title::text,r.summary::text,r.kind::text,r.updated_at
  from public.learning_resources r
  where r.status='published' and not r.moderation_hidden
    and (p_ids is null or r.id=any(p_ids));
$$;
-- Transfer only this reader, preserving existing schema privileges.
do $$ declare had_create boolean := has_schema_privilege('authenticated','public','CREATE'); begin
  if not had_create then grant create on schema public to authenticated; end if;
  alter function public.recommendation_rls_resources(uuid[]) owner to authenticated;
  if not had_create then revoke create on schema public from authenticated; end if;
end $$;
revoke all on function public.recommendation_rls_resources(uuid[]) from public,anon;
grant execute on function public.recommendation_rls_resources(uuid[]) to service_role;

-- Only the backend can substitute the recipient. Never accept a client token or
-- caller-supplied owner. Claims are restored even if a policy/reader fails.
create function public.recommendation_resources_for_recipient(p_user_id uuid,p_ids uuid[] default null)
returns table(id uuid,title text,summary text,kind text,updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare previous_claims text := current_setting('request.jwt.claims',true);
  previous_sub text := current_setting('request.jwt.claim.sub',true);
  previous_role text := current_setting('request.jwt.claim.role',true);
  claims jsonb;
begin
  select jsonb_build_object('sub',u.id,'role','authenticated','aud','authenticated',
    'aal','aal1','email',u.email,'app_metadata',coalesce(u.raw_app_meta_data,'{}'::jsonb),
    'user_metadata',coalesce(u.raw_user_meta_data,'{}'::jsonb)) into claims
  from auth.users u where u.id=p_user_id;
  if claims is null then return; end if;
  perform set_config('request.jwt.claims',claims::text,true);
  perform set_config('request.jwt.claim.sub',p_user_id::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  return query select * from public.recommendation_rls_resources(p_ids);
  perform set_config('request.jwt.claims',coalesce(previous_claims,''),true);
  perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
  perform set_config('request.jwt.claim.role',coalesce(previous_role,''),true);
exception when others then
  perform set_config('request.jwt.claims',coalesce(previous_claims,''),true);
  perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
  perform set_config('request.jwt.claim.role',coalesce(previous_role,''),true);
  raise;
end $$;

create function public.stalled_period_alert_state(p_task_id uuid,p_user_id uuid,p_stalled_at timestamptz)
returns text language sql stable security invoker set search_path='' as $$
  select case when not exists(
    select 1 from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id
    join public.projects p on p.id=b.project_id join public.profiles pr on pr.id=p.owner_id
    where t.id=p_task_id and p.owner_id=p_user_id and p.status='active'
      and not b.is_archived and not t.is_archived and t.status<>'completed'
      and t.is_stalled and t.stalled_at=p_stalled_at
  ) then 'ineligible' when exists(
    select 1 from public.notifications n where n.user_id=p_user_id and n.task_id=p_task_id
      and n.type in ('STALLED_TASK','LEARNING_RESOURCE_RECOMMENDATION')
      and n.created_at>=p_stalled_at
  ) then 'handled' else 'eligible' end;
$$;

-- Serialize both categories on the task row. Recheck state, preferences and
-- recipient RLS immediately before enqueueing. The existing INSERT webhook
-- handles push; there is never a second transport call here.
create function public.enqueue_stalled_period_alert(
  p_task_id uuid,p_user_id uuid,p_stalled_at timestamptz,
  p_resource_id uuid default null,p_resource_version text default null,p_task_version text default null)
returns boolean language plpgsql security invoker set search_path='' set timezone='UTC' as $$
declare ctx record; prefs record; resource record; category text; episode text;
  use_recommendation boolean := false; payload jsonb;
begin
  select t.*,b.project_id,p.owner_id into ctx from public.kanban_tasks t
    join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
    where t.id=p_task_id and p.owner_id=p_user_id and p.status='active'
      and not b.is_archived and not t.is_archived and t.status<>'completed'
      and t.is_stalled and t.stalled_at=p_stalled_at
    for update of t for share of b,p;
  if not found or public.stalled_period_alert_state(p_task_id,p_user_id,p_stalled_at)<>'eligible' then return false; end if;
  select stalled_task_enabled,recommendation_enabled into prefs
    from public.notification_preferences where user_id=p_user_id for share;
  if p_resource_id is not null and coalesce(prefs.recommendation_enabled,true) then
    -- Locks prevent a concurrent hide/edit from racing the final check/insert.
    perform 1 from public.learning_resources where id=p_resource_id for share;
    perform 1 from public.resource_index where resource_id=p_resource_id for share;
    perform 1 from public.resource_embeddings where resource_id=p_resource_id for share;
    perform 1 from storage.objects o join public.video_transcripts t
      on o.id::text=t.source_file_id where t.resource_id=p_resource_id::text for share of o;
    select s.* into resource from public.recommendation_index_sources s
      join public.resource_embeddings e on e.resource_id=s.resource_id
      where s.resource_id=p_resource_id and s.source_version=p_resource_version
        and e.status='ready' and e.indexed_version=s.source_version
        and exists(select 1 from public.recommendation_resources_for_recipient(p_user_id,array[p_resource_id]))
        and exists(select 1 from public.recommendation_load_owned_task(p_task_id,p_user_id) t
          where t.is_stalled and t.source_version=p_task_version);
    use_recommendation := found;
  end if;
  if not use_recommendation and not coalesce(prefs.stalled_task_enabled,true) then return false; end if;
  category := case when use_recommendation then 'LEARNING_RESOURCE_RECOMMENDATION' else 'STALLED_TASK' end;
  episode := to_char(p_stalled_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  payload := jsonb_build_object('user_id',p_user_id,'type',category,
    'context_type',case when use_recommendation then 'RECOMMENDATION' else 'TASK' end,
    'project_id',ctx.project_id,'board_id',ctx.board_id,'task_id',p_task_id,
    'title',case when use_recommendation then 'Resources to help you get unstuck' else 'Task may be stalled' end,
    'message',case when use_recommendation then format('“%s” may help with “%s”.',left(resource.title,150),left(ctx.title,150))
      else format('“%s” has a stagnation score of %s/100.',ctx.title,ctx.stagnation_score) end,
    'unique_key',lower(category)||':'||p_task_id::text||':'||episode,
    'action_data',case when use_recommendation then jsonb_build_object('section','learning_resources','resource_id',p_resource_id,'stalled_at',episode)
      else jsonb_build_object('stalled_at',episode) end);
  return public.enqueue_app_notification(payload);
end $$;

revoke all on function public.recommendation_resources_for_recipient(uuid,uuid[]) from public,anon,authenticated;
revoke all on function public.stalled_period_alert_state(uuid,uuid,timestamptz) from public,anon,authenticated;
revoke all on function public.enqueue_stalled_period_alert(uuid,uuid,timestamptz,uuid,text,text) from public,anon,authenticated;
grant execute on function public.recommendation_resources_for_recipient(uuid,uuid[]) to service_role;
grant execute on function public.stalled_period_alert_state(uuid,uuid,timestamptz) to service_role;
grant execute on function public.enqueue_stalled_period_alert(uuid,uuid,timestamptz,uuid,text,text) to service_role;
-- Matching may exceed pg_net's five-second default. Keep the existing cron and secrets.
create or replace function public.invoke_project_notification_generator()
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare project_url text;
declare cron_secret text;
begin
  select decrypted_secret into project_url
  from vault.decrypted_secrets where name = 'project_notification_url';
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets where name = 'project_notification_cron_secret';
  if nullif(project_url, '') is null or nullif(cron_secret, '') is null then
    raise warning 'Notification cron secrets are not configured';
    return;
  end if;
  perform net.http_post(
    url := rtrim(project_url, '/') || '/functions/v1/project-notification-generator',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-notification-cron-secret', cron_secret),
    body := '{}'::jsonb, timeout_milliseconds := 75000
  );
end;
$$;

revoke all on function public.invoke_project_notification_generator()
  from public, anon, authenticated, service_role;

notify pgrst,'reload schema';
commit;
