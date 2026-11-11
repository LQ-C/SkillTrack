-- Prerequisites: canonical project/task/catalog schema and migrations 009-014.
-- Apply once, before redeploying both recommendation callers.
begin;
-- One current set, including successful empty generations. Pending refresh state
-- never replaces the last successful generation until its transaction commits.
create table public.task_recommendation_sets (
 task_id uuid primary key references public.kanban_tasks(id) on delete cascade,
 generation_id uuid, generated_at timestamptz, task_version text, stalled_at timestamptz,
 model_id text, text_version text,
 claim_token uuid, claim_version text, claim_mode text, lease_expires_at timestamptz
);
create table public.task_recommendation_items (
 task_id uuid not null references public.task_recommendation_sets(task_id) on delete cascade,
 resource_id uuid not null references public.learning_resources(id) on delete cascade,
 position integer not null check(position between 0 and 2), source_version text not null,
 primary key(task_id,resource_id), unique(task_id,position)
);
create index task_recommendation_resource_idx on public.task_recommendation_items(resource_id);
alter table public.task_recommendation_sets enable row level security;
alter table public.task_recommendation_items enable row level security;
create policy recommendation_set_read on public.task_recommendation_sets for select to authenticated
 using(public.owns_bookmark_task(task_id));
create policy recommendation_item_read on public.task_recommendation_items for select to authenticated
 using(public.owns_bookmark_task(task_id));
revoke all on public.task_recommendation_sets,public.task_recommendation_items from public,anon,authenticated;
grant select on public.task_recommendation_sets,public.task_recommendation_items to authenticated;
grant select,insert,update,delete on public.task_recommendation_sets,public.task_recommendation_items to service_role;

create function public.task_recommendations(p_task_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not public.owns_bookmark_task(p_task_id) then raise exception 'Task access denied' using errcode='42501'; end if;
 select jsonb_build_object('generated',s.generation_id is not null,'generation_id',s.generation_id,
   'generated_at',s.generated_at,'stalled_at',s.stalled_at,'recommendations',coalesce((
   select jsonb_agg(jsonb_build_object('resource_id',r.id,'title',r.title,'summary',coalesce(r.summary,''),'type',r.kind) order by i.position)
   from public.task_recommendation_items i join public.learning_resources r on r.id=i.resource_id
   where i.task_id=s.task_id and r.status='published' and not r.moderation_hidden),'[]'::jsonb)) into result
 from public.task_recommendation_sets s where s.task_id=p_task_id;
 return coalesce(result,'{"generated":false,"recommendations":[]}'::jsonb);
end $$;

create function public.read_task_recommendations(p_task_id uuid,p_user_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare s public.task_recommendation_sets%rowtype; task public.kanban_tasks%rowtype; items jsonb; sources jsonb;
begin
 select t.* into task from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id
 join public.projects p on p.id=b.project_id where t.id=p_task_id and p.owner_id=p_user_id;
 if not found then raise exception 'Task access denied' using errcode='42501'; end if;
 select * into s from public.task_recommendation_sets where task_id=p_task_id;
 select coalesce(jsonb_agg(jsonb_build_object('resource_id',r.id,'title',r.title,'summary',coalesce(r.summary,''),'type',r.kind) order by i.position),'[]'),
 coalesce(jsonb_agg(jsonb_build_object('resource_id',r.id,'source_version',i.source_version) order by i.position),'[]') into items,sources
 from public.task_recommendation_items i join public.recommendation_resources_for_recipient(p_user_id,
   array(select resource_id from public.task_recommendation_items where task_id=p_task_id)) r on r.id=i.resource_id
 where i.task_id=p_task_id;
 return jsonb_build_object('generated',s.generation_id is not null,'generation_id',s.generation_id,'generated_at',s.generated_at,
 'stalled_at',s.stalled_at,'task_version',s.task_version,'sources',sources,'recommendations',items,
 'status',case when jsonb_array_length(items)>0 then 'ok' else 'empty' end);
end $$;

create function public.begin_task_recommendations(p_task_id uuid,p_user_id uuid,p_mode text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare t public.kanban_tasks%rowtype; s public.task_recommendation_sets%rowtype; version text; token uuid;
begin
 if p_mode is null or p_mode not in ('manual','automatic') then raise exception 'Invalid mode'; end if;
 select task.* into t from public.kanban_tasks task join public.kanban_boards b on b.id=task.board_id
 join public.projects p on p.id=b.project_id where task.id=p_task_id and p.owner_id=p_user_id
 and p.status='active' and not b.is_archived and not task.is_archived and task.status<>'completed' for update of task;
 if not found then raise exception 'Task ineligible' using errcode='42501'; end if;
 if p_mode='automatic' and not t.is_stalled then return jsonb_build_object('cached',true,'result',public.read_task_recommendations(p_task_id,p_user_id)); end if;
 insert into public.task_recommendation_sets(task_id) values(p_task_id) on conflict do nothing;
 select * into s from public.task_recommendation_sets where task_id=p_task_id for update;
 if p_mode='automatic' and s.generation_id is not null and s.stalled_at is not distinct from t.stalled_at then
  return jsonb_build_object('cached',true,'result',public.read_task_recommendations(p_task_id,p_user_id)); end if;
 if s.lease_expires_at>clock_timestamp() then raise exception 'Recommendation generation busy' using errcode='55P03'; end if;
 version:=encode(sha256(convert_to(jsonb_build_array(t.title,t.description,t.status,t.is_stalled,t.stalled_at,to_jsonb(t)->'updated_at')::text,'UTF8')),'hex');
 token:=gen_random_uuid();
 update public.task_recommendation_sets set claim_token=token,claim_version=version,claim_mode=p_mode,
 lease_expires_at=clock_timestamp()+interval '90 seconds' where task_id=p_task_id;
 return jsonb_build_object('cached',false,'token',token);
end $$;

create function public.complete_task_recommendations(p_task_id uuid,p_user_id uuid,p_token uuid,p_sources jsonb,p_model_id text,p_text_version text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare t public.kanban_tasks%rowtype; s public.task_recommendation_sets%rowtype; version text; item jsonb; position integer:=0;
begin
 select task.* into t from public.kanban_tasks task join public.kanban_boards b on b.id=task.board_id
 join public.projects p on p.id=b.project_id where task.id=p_task_id and p.owner_id=p_user_id
 and p.status='active' and not b.is_archived and not task.is_archived and task.status<>'completed' for update of task for share of b,p;
 if not found then raise exception 'Task ineligible' using errcode='42501'; end if;
 select * into s from public.task_recommendation_sets where task_id=p_task_id for update;
 if s.generation_id=p_token then return public.read_task_recommendations(p_task_id,p_user_id); end if;
 version:=encode(sha256(convert_to(jsonb_build_array(t.title,t.description,t.status,t.is_stalled,t.stalled_at,to_jsonb(t)->'updated_at')::text,'UTF8')),'hex');
 if p_token is null or s.claim_token is distinct from p_token or s.lease_expires_at<=clock_timestamp()
 or s.claim_version is distinct from version or (s.claim_mode='automatic' and not t.is_stalled) then
 raise exception 'Stale recommendation generation' using errcode='40001'; end if;
 if p_sources is null or jsonb_typeof(p_sources)<>'array' or jsonb_array_length(p_sources)>3
 or p_model_id is distinct from 'gte-small' or p_text_version is distinct from 'skilltrack-v1-chunk400-mean-l2' then
 raise exception 'Invalid recommendations' using errcode='22023'; end if;
 for item in select value from jsonb_array_elements(p_sources) loop
  perform 1 from public.learning_resources where id=(item->>'resource_id')::uuid for share;
  perform 1 from public.resource_embeddings where resource_id=(item->>'resource_id')::uuid for share;
  perform 1 from public.resource_index where resource_id=(item->>'resource_id')::uuid for share;
  perform 1 from storage.objects o join public.resource_extractions e on o.id::text=e.source_file_id
   where e.resource_id=item->>'resource_id' for share of o;
  if not exists(select 1 from public.recommendation_index_sources src join public.resource_embeddings e on e.resource_id=src.resource_id
    where src.resource_id=(item->>'resource_id')::uuid and src.source_version=item->>'source_version'
    and e.status='ready' and e.indexed_version=src.source_version
    and exists(select 1 from public.recommendation_resources_for_recipient(p_user_id,array[src.resource_id]))) then
    raise exception 'Resource changed or unavailable' using errcode='40001'; end if;
 end loop;
 delete from public.task_recommendation_items where task_id=p_task_id;
 for item in select value from jsonb_array_elements(p_sources) loop
  insert into public.task_recommendation_items values(p_task_id,(item->>'resource_id')::uuid,position,item->>'source_version');position:=position+1;
 end loop;
 update public.task_recommendation_sets set generation_id=p_token,generated_at=clock_timestamp(),stalled_at=t.stalled_at,
 task_version=(select source_version from public.recommendation_load_owned_task(p_task_id,p_user_id,'manual')),
 model_id=p_model_id,text_version=p_text_version,claim_token=null,claim_version=null,claim_mode=null,lease_expires_at=null
 where task_id=p_task_id;
 return public.read_task_recommendations(p_task_id,p_user_id);
end $$;

create function public.fail_task_recommendations(p_task_id uuid,p_user_id uuid,p_token uuid)
returns void language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
 where t.id=p_task_id and p.owner_id=p_user_id) then raise exception 'Task access denied' using errcode='42501'; end if;
 update public.task_recommendation_sets set claim_token=null,claim_version=null,claim_mode=null,lease_expires_at=null
 where task_id=p_task_id and claim_token=p_token;
end $$;
revoke all on function public.task_recommendations(uuid) from public,anon;
grant execute on function public.task_recommendations(uuid) to authenticated;
do $$ declare fn record; begin
 for fn in select oid::regprocedure signature from pg_proc where pronamespace='public'::regnamespace
 and proname in ('read_task_recommendations','begin_task_recommendations','complete_task_recommendations','fail_task_recommendations') loop
 execute format('revoke all on function %s from public,anon,authenticated',fn.signature);
 execute format('grant execute on function %s to service_role',fn.signature);end loop;
end $$;
notify pgrst,'reload schema';
commit;
