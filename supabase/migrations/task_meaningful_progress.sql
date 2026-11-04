-- Apply AFTER task_deadline_timezone.sql and the existing atomic write/milestone setup.
-- Uses existing tables, activity action values and RLS. No history is rewritten.
begin;
do $prerequisites$
begin
  if to_regclass('public.kanban_write_requests') is null
    or to_regprocedure('public.assert_owned_kanban_board(uuid)') is null
    or to_regprocedure('public.notification_task_candidates(integer,integer)') is null
    or not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='kanban_tasks' and column_name='deadline_has_time') then
    raise exception 'Apply the existing atomic write and task_deadline_timezone migrations first';
  end if;
end;
$prerequisites$;

create or replace function public.is_meaningful_task_activity(p_action text,p_old jsonb,p_new jsonb)
returns boolean language sql immutable set search_path=public,pg_temp as $$
  select coalesce(
    p_action='resumed'
    or (p_action='completed' and coalesce(p_new->>'status','completed')='completed'
      and p_old->>'status' is distinct from 'completed')
    or (p_action in ('moved','reopened') and p_new->>'status' in ('in_progress','completed')
      and p_old->>'status' is not null and p_old->>'status' is distinct from p_new->>'status')
    or (p_action='checklist_updated' and p_old->'is_completed'='false'::jsonb
      and p_new->'is_completed'='true'::jsonb)
    or (p_action='updated' and p_new->>'change'='progress_update'
      and jsonb_typeof(p_new->'progress_text')='string'
      and length(regexp_replace(p_new->>'progress_text','^[[:space:]]+|[[:space:]]+$','','g')) between 1 and 1000),
    false);
$$;
revoke all on function public.is_meaningful_task_activity(text,jsonb,jsonb) from public,anon;
grant execute on function public.is_meaningful_task_activity(text,jsonb,jsonb) to authenticated,service_role;

create or replace function public.task_progress_at(p_task_id uuid)
returns timestamptz language sql stable security invoker set search_path=public,pg_temp as $$
  select coalesce((select max(l.created_at) from public.task_activity_logs l
    where l.task_id=t.id and isfinite(l.created_at)
      and public.is_meaningful_task_activity(l.action::text,l.old_values,l.new_values)),t.created_at)
  from public.kanban_tasks t where t.id=p_task_id;
$$;
revoke all on function public.task_progress_at(uuid) from public,anon;
grant execute on function public.task_progress_at(uuid) to authenticated,service_role;

-- Fence meaningful inserts against a monitor that holds the same task row lock.
-- Read server time AFTER the lock; progress also wins if it commits after monitoring.
create or replace function public.record_meaningful_task_progress()
returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
begin
  if public.is_meaningful_task_activity(new.action::text,new.old_values,new.new_values) then
    perform t.id from public.kanban_tasks t where t.id=new.task_id for update;
    if not found then raise exception 'Task unavailable' using errcode='42501'; end if;
    new.created_at:=clock_timestamp();
    update public.kanban_tasks set stagnation_score=0,is_stalled=false,stalled_at=null,
      stagnation_checked_at=new.created_at where id=new.task_id;
  end if;
  return new;
end;
$$;
revoke all on function public.record_meaningful_task_progress() from public,anon,authenticated;
drop trigger if exists task_activity_meaningful_progress on public.task_activity_logs;
create trigger task_activity_meaningful_progress before insert on public.task_activity_logs
  for each row execute function public.record_meaningful_task_progress();

create or replace function public.update_task_checklist_item(
  p_item_id uuid,p_title text,p_position integer,p_is_completed boolean
) returns public.task_checklist_items language plpgsql security invoker
set search_path=public,pg_temp as $$
declare
  previous public.task_checklist_items;
  saved public.task_checklist_items;
  task_board uuid;
  v_task_id uuid;
  at_time timestamptz;
begin
  if auth.uid() is null then raise exception 'Sign in to edit checklist items' using errcode='42501'; end if;
  if p_title is null or length(btrim(p_title))=0 or p_position is null
    or p_position<0 or p_is_completed is null then
    raise exception 'Invalid checklist item' using errcode='22023';
  end if;
  select i.task_id,t.board_id into v_task_id,task_board from public.task_checklist_items i
    join public.kanban_tasks t on t.id=i.task_id where i.id=p_item_id;
  if not found then raise exception 'Checklist item unavailable' using errcode='42501'; end if;
  perform public.assert_owned_kanban_board(task_board);
  perform t.id from public.kanban_tasks t where t.id=v_task_id and not coalesce(t.is_archived,false) for update;
  if not found then raise exception 'Task unavailable' using errcode='42501'; end if;
  select * into previous from public.task_checklist_items i where i.id=p_item_id and i.task_id=v_task_id for update;
  if not found then raise exception 'Checklist item unavailable' using errcode='42501'; end if;
  at_time:=clock_timestamp();
  update public.task_checklist_items set title=btrim(p_title),position=p_position,is_completed=p_is_completed,
    completed_at=case when not p_is_completed then null when previous.is_completed
      then previous.completed_at else at_time end
    where id=p_item_id returning * into saved;
  insert into public.task_activity_logs(task_id,action,old_values,new_values)
    values(saved.task_id,'checklist_updated',
      jsonb_build_object('item_id',saved.id,'is_completed',previous.is_completed,'title',previous.title),
      jsonb_build_object('item_id',saved.id,'is_completed',saved.is_completed,'title',saved.title));
  return saved;
end;
$$;
revoke all on function public.update_task_checklist_item(uuid,text,integer,boolean) from public,anon;
grant execute on function public.update_task_checklist_item(uuid,text,integer,boolean) to authenticated;

create or replace function public.add_task_progress_update(p_task_id uuid,p_request_id text,p_text text)
returns public.task_activity_logs language plpgsql security invoker set search_path=public,pg_temp as $$
declare
  normalized text:=regexp_replace(p_text,'^[[:space:]]+|[[:space:]]+$','','g');
  task_board uuid;
  receipt public.kanban_write_requests;
  activity public.task_activity_logs;
begin
  if auth.uid() is null then raise exception 'Sign in to add progress updates' using errcode='42501'; end if;
  if p_request_id is null or length(p_request_id) not between 16 and 128
    or normalized is null or length(normalized) not between 1 and 1000 then
    raise exception 'Enter a progress update of 1-1000 characters' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id,0));
  select t.board_id into task_board from public.kanban_tasks t where t.id=p_task_id;
  if not found then raise exception 'Task unavailable' using errcode='42501'; end if;
  perform public.assert_owned_kanban_board(task_board);
  perform t.id from public.kanban_tasks t where t.id=p_task_id and not coalesce(t.is_archived,false) for update;
  if not found then raise exception 'Task unavailable' using errcode='42501'; end if;
  select * into receipt from public.kanban_write_requests where user_id=auth.uid() and request_id=p_request_id;
  if found then
    if receipt.board_id<>task_board or receipt.payload->>'format' is distinct from 'task-progress-v1'
      or receipt.payload->>'task_id' is distinct from p_task_id::text
      or receipt.payload->>'text' is distinct from normalized then
      raise exception 'Request identifier already used for another payload' using errcode='22023';
    end if;
    select * into activity from public.task_activity_logs where id=(receipt.payload->>'activity_id')::uuid and task_id=p_task_id;
    if not found then raise exception 'Saved progress update unavailable' using errcode='22023'; end if;
    return activity;
  end if;
  insert into public.task_activity_logs(task_id,action,old_values,new_values)
    values(p_task_id,'updated','{}'::jsonb,jsonb_build_object('change','progress_update','progress_text',normalized))
    returning * into activity;
  insert into public.kanban_write_requests(user_id,request_id,board_id,payload,saved_count)
    values(auth.uid(),p_request_id,task_board,jsonb_build_object('format','task-progress-v1',
      'task_id',p_task_id,'text',normalized,'activity_id',activity.id),1);
  return activity;
end;
$$;
revoke all on function public.add_task_progress_update(uuid,text,text) from public,anon;
grant execute on function public.add_task_progress_update(uuid,text,text) to authenticated;

-- Preserve monitoring-only updated_at values even when a generic touch trigger exists.
create or replace function public.preserve_stagnation_activity_timestamp()
returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
begin
  if current_setting('skilltrack.stagnation_task_id',true)=old.id::text
    and (to_jsonb(new)-array['stagnation_score','is_stalled','stalled_at','stagnation_checked_at','updated_at'])
      =(to_jsonb(old)-array['stagnation_score','is_stalled','stalled_at','stagnation_checked_at','updated_at']) then
    new.updated_at:=old.updated_at;
  end if;
  return new;
end;
$$;
revoke all on function public.preserve_stagnation_activity_timestamp() from public,anon,authenticated;
drop trigger if exists zz_preserve_stagnation_activity_timestamp on public.kanban_tasks;
create trigger zz_preserve_stagnation_activity_timestamp before update on public.kanban_tasks
  for each row execute function public.preserve_stagnation_activity_timestamp();

-- The verified live score type is smallint (default now()); an older checked-in
-- installation uses integer without a default. Replace only the installed signature.
do $install$
declare
  installed regprocedure;
  arguments text;
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='update_task_stagnation')<>1 then
    raise exception 'Expected one update_task_stagnation RPC; inspect installed overloads';
  end if;
  installed:=coalesce(to_regprocedure('public.update_task_stagnation(uuid,smallint,timestamptz)'),
    to_regprocedure('public.update_task_stagnation(uuid,integer,timestamptz)'));
  if installed is null then raise exception 'Unsupported update_task_stagnation signature'; end if;
  select pg_get_function_arguments(installed) into arguments;
  execute format($definition$
create or replace function public.update_task_stagnation(%s)
returns table(became_stalled boolean,currently_stalled boolean,current_stalled_at timestamptz)
language plpgsql security invoker set search_path=public,pg_temp set timezone='UTC' as $body$
declare
  task public.kanban_tasks;
  progress_at timestamptz;
  next_stalled boolean;
  episode timestamptz;
  previous_marker text;
begin
  if p_task_id is null or p_score is null or p_score not between 0 and 100
    or p_checked_at is null or not isfinite(p_checked_at) then
    raise exception 'Invalid stagnation update' using errcode='22023';
  end if;
  select t.* into task from public.kanban_tasks t
    join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
    join public.profiles pr on pr.id=p.owner_id
    where t.id=p_task_id and p.status='active' and not coalesce(b.is_archived,false)
      and not coalesce(t.is_archived,false) and t.status<>'completed' for update of t;
  if not found then raise exception 'Task is not eligible for stagnation processing' using errcode='P0002'; end if;
  progress_at:=public.task_progress_at(p_task_id);
  if progress_at>=p_checked_at or task.stagnation_checked_at>p_checked_at then
    raise exception 'Stale stagnation calculation; retry with fresh candidates' using errcode='40001';
  end if;
  next_stalled:=p_score>=70;
  episode:=case when next_stalled then case when coalesce(task.is_stalled,false)
    then coalesce(task.stalled_at,p_checked_at) else p_checked_at end else null end;
  previous_marker:=current_setting('skilltrack.stagnation_task_id',true);
  perform set_config('skilltrack.stagnation_task_id',p_task_id::text,true);
  update public.kanban_tasks set stagnation_score=p_score,is_stalled=next_stalled,
    stalled_at=episode,stagnation_checked_at=p_checked_at where id=p_task_id;
  perform set_config('skilltrack.stagnation_task_id',coalesce(previous_marker,''),true);
  if public.task_progress_at(p_task_id) is distinct from progress_at then
    raise exception 'Progress changed during monitoring; retry with fresh candidates' using errcode='40001';
  end if;
  return query select next_stalled and not coalesce(task.is_stalled,false),next_stalled,episode;
end;
$body$;
$definition$,arguments);
  execute format('revoke all on function %s from public,anon,authenticated',installed);
  execute format('grant execute on function %s to service_role',installed);
end;
$install$;

-- Preserve the current 14-column candidate contract, including deadline intent.
create or replace function public.notification_task_candidates(p_offset integer,p_limit integer)
returns table(task_id uuid,board_id uuid,project_id uuid,user_id uuid,task_title text,task_status text,
  task_archived boolean,board_archived boolean,project_status text,profile_exists boolean,
  deadline text,last_activity_at text,task_created_at text,deadline_has_time boolean)
language sql stable security invoker set search_path=public,pg_temp set timezone='UTC' as $$
  select t.id,b.id,p.id,p.owner_id,t.title::text,t.status::text,
    coalesce(t.is_archived,false),coalesce(b.is_archived,false),p.status::text,pr.id is not null,
    t.deadline::text,public.task_progress_at(t.id)::text,t.created_at::text,t.deadline_has_time
  from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id
    join public.projects p on p.id=b.project_id left join public.profiles pr on pr.id=p.owner_id
  where p.status='active' and not coalesce(b.is_archived,false)
    and not coalesce(t.is_archived,false) and t.status<>'completed'
  order by t.id offset greatest(p_offset,0) limit least(greatest(p_limit,1),500);
$$;
commit;
notify pgrst,'reload schema';
