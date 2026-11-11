-- Requires 001-008, the real marketplace schema and SkillTrack task tables.
-- No resource_analysis copy, marketplace RLS changes, Storage grants or local worker.
begin;
create schema if not exists extensions;
create extension if not exists vector with schema extensions;
do $$ begin
  if (select n.nspname from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='vector')<>'extensions' then
    raise exception 'Review existing vector extension schema before applying';
  end if;
end $$;

-- Only analysis for the CURRENT resource/file can become an embedding source.
-- The ready job is the provenance missing from resource_index's four columns.
create view public.recommendation_index_sources as
select r.id resource_id,r.title,r.summary,concat_ws(' ',r.summary,r.category) description,
  r.kind resource_type,r.body pdf_text,coalesce(t.transcript_text,'') transcript,
  i.keywords,i.topic_tags,r.updated_at resource_updated_at,
  encode(sha256(convert_to(jsonb_build_array(c.content_version,i.keywords,i.topic_tags)::text,'UTF8')),'hex') source_version
from public.learning_resources r
join public.resource_analysis_candidates(null,false) c on c.resource_id=r.id
join public.resource_index i on i.resource_id=r.id
join public.resource_analysis_jobs j on j.resource_id=r.id and j.content_version=c.content_version
  and j.status='ready' and j.updated_at>=i.analysed_at
left join public.video_transcripts t on t.id=c.transcript_id
where r.status='published' and r.moderation_hidden=false;
revoke all on public.recommendation_index_sources from public,anon,authenticated;
grant select on public.recommendation_index_sources to service_role;

-- One row per real UUID. Work state and the vector share a table; no second job queue.
create table public.resource_embeddings (
  resource_id uuid primary key references public.learning_resources(id) on delete cascade,
  source_version text not null,
  indexed_version text,
  embedding extensions.vector(384),
  model_id text not null default 'gte-small' check(model_id='gte-small'),
  text_version text not null default 'skilltrack-v1-chunk400-mean-l2' check(text_version='skilltrack-v1-chunk400-mean-l2'),
  keywords text[] not null default '{}',topic_tags text[] not null default '{}',
  domains text[] not null default '{}',frameworks text[] not null default '{}',
  status text not null default 'pending' check(status in ('pending','processing','ready','failed','skipped')),
  attempt_count integer not null default 0 check(attempt_count>=0),
  claim_token uuid,lease_expires_at timestamptz,next_attempt_at timestamptz not null default now(),error_code text,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  check((status='processing')=(lease_expires_at is not null)),
  check(status<>'processing' or claim_token is not null),
  check(status<>'ready' or (embedding is not null and indexed_version=source_version)),
  check(embedding is null or extensions.vector_norm(embedding)>0)
);
alter table public.resource_embeddings enable row level security;
revoke all on public.resource_embeddings from public,anon,authenticated;
grant select,insert,update,delete on public.resource_embeddings to service_role;
grant usage on schema extensions to service_role;
create index resource_embeddings_pending on public.resource_embeddings(status,next_attempt_at,lease_expires_at);

create function public.enqueue_resource_embedding(p_resource_id uuid)
returns boolean language plpgsql security invoker set search_path='' as $$
declare version text;
begin
  select source_version into version from public.recommendation_index_sources where resource_id=p_resource_id;
  if not found then return false; end if;
  insert into public.resource_embeddings(resource_id,source_version) values(p_resource_id,version)
  on conflict(resource_id) do update set source_version=excluded.source_version,
    status='pending',attempt_count=0,claim_token=null,lease_expires_at=null,error_code=null,
    next_attempt_at=clock_timestamp(),updated_at=clock_timestamp()
    where resource_embeddings.source_version<>excluded.source_version;
  return found;
end $$;

create function public.queue_resource_embedding_after_analysis()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if new.status='ready' then perform public.enqueue_resource_embedding(new.resource_id); end if;
  return new;
end $$;
create trigger resource_analysis_ready_embedding after insert or update of status on public.resource_analysis_jobs
  for each row execute function public.queue_resource_embedding_after_analysis();

create function public.backfill_resource_embeddings(p_limit integer default 25)
returns integer language plpgsql security invoker set search_path='' as $$
declare source record; total integer:=0;
begin
  if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid batch size' using errcode='22023'; end if;
  for source in select s.resource_id from public.recommendation_index_sources s
    left join public.resource_embeddings e on e.resource_id=s.resource_id
    where e.resource_id is null or e.source_version<>s.source_version order by s.resource_id limit p_limit
  loop if public.enqueue_resource_embedding(source.resource_id) then total:=total+1; end if; end loop;
  return total;
end $$;

create function public.claim_resource_embedding()
returns jsonb language plpgsql security invoker set search_path='' as $$
declare work public.resource_embeddings%rowtype; source public.recommendation_index_sources%rowtype;
begin
  update public.resource_embeddings set status='failed',claim_token=null,lease_expires_at=null,error_code='lease_expired',updated_at=clock_timestamp()
    where status='processing' and lease_expires_at<=clock_timestamp() and attempt_count>=3;
  -- Changed or withdrawn sources never spend another model request. Backfill
  -- resets the row only for a new source version, not for repeated failed work.
  update public.resource_embeddings e set status='skipped',claim_token=null,lease_expires_at=null,error_code='source_changed',updated_at=clock_timestamp()
    where e.status in ('pending','processing') and not exists(select 1 from public.recommendation_index_sources s
      where s.resource_id=e.resource_id and s.source_version=e.source_version);
  select * into work from public.resource_embeddings
    where attempt_count<3 and ((status='pending' and next_attempt_at<=clock_timestamp())
      or (status='processing' and lease_expires_at<=clock_timestamp()))
    order by next_attempt_at,resource_id limit 1 for update skip locked;
  if not found then return null; end if;
  update public.resource_embeddings set status='processing',attempt_count=attempt_count+1,
    claim_token=gen_random_uuid(),lease_expires_at=clock_timestamp()+interval '180 seconds',updated_at=clock_timestamp()
    where resource_id=work.resource_id returning * into work;
  select * into source from public.recommendation_index_sources where resource_id=work.resource_id and source_version=work.source_version;
  return jsonb_build_object('resource_id',work.resource_id,'claim_token',work.claim_token,'source',to_jsonb(source));
end $$;

create function public.complete_resource_embedding(p_resource_id uuid,p_claim_token uuid,p_source_version text,
  p_embedding extensions.vector(384),p_keywords text[],p_topic_tags text[],p_domains text[],p_frameworks text[])
returns boolean language plpgsql security invoker set search_path='' as $$
begin
  if p_embedding is null or extensions.vector_dims(p_embedding)<>384 or extensions.vector_norm(p_embedding)<=0
    or p_keywords is null or p_topic_tags is null or p_domains is null or p_frameworks is null then
    raise exception 'Invalid embedding' using errcode='22023';
  end if;
  -- Lock order matches source editing -> analysis completion -> embedding enqueue.
  perform 1 from public.learning_resources where id=p_resource_id for share;
  update public.resource_embeddings e set embedding=p_embedding,indexed_version=p_source_version,
    keywords=p_keywords,topic_tags=p_topic_tags,domains=p_domains,frameworks=p_frameworks,
    status='ready',lease_expires_at=null,error_code=null,updated_at=clock_timestamp()
    where e.resource_id=p_resource_id and e.claim_token=p_claim_token and e.status='processing'
      and e.lease_expires_at>clock_timestamp() and e.source_version=p_source_version
      and exists(select 1 from public.recommendation_index_sources s where s.resource_id=e.resource_id and s.source_version=p_source_version);
  return found;
end $$;

create function public.fail_resource_embedding(p_resource_id uuid,p_claim_token uuid,p_error_code text)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
  if p_error_code not in ('embedding_unavailable','source_changed') or p_error_code is null then
    raise exception 'Invalid failure' using errcode='22023'; end if;
  update public.resource_embeddings set status=case when p_error_code='source_changed' then 'skipped' when attempt_count>=3 then 'failed' else 'pending' end,
    claim_token=null,lease_expires_at=null,error_code=p_error_code,next_attempt_at=clock_timestamp()+make_interval(secs=>60*attempt_count),updated_at=clock_timestamp()
    where resource_id=p_resource_id and claim_token=p_claim_token and status='processing' and lease_expires_at>clock_timestamp();
  return found;
end $$;

create function public.recommendation_load_owned_task(p_task_id uuid,p_user_id uuid)
returns table(title text,description text,is_stalled boolean,source_version text)
language sql stable security invoker set search_path='' as $$
  select case when t.is_stalled and t.status<>'completed' then t.title::text end,
    case when t.is_stalled and t.status<>'completed' then coalesce(t.description,'') end,
    t.is_stalled and t.status<>'completed',
    encode(sha256(convert_to(jsonb_build_array(t.title,t.description,t.is_stalled,t.status)::text,'UTF8')),'hex')
  from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
  where t.id=p_task_id and p.owner_id=p_user_id and p.status='active' and not b.is_archived and not t.is_archived;
$$;

create function public.recommendation_jaccard(a text[],b text[])
returns double precision language sql immutable security invoker set search_path='' as $$
  select coalesce((select count(*)::double precision from
    (select unnest(a) intersect select unnest(b)) i) /
    nullif((select count(*) from (select unnest(a) union select unnest(b)) u),0),0)
$$;

create function public.match_resource_embeddings(
  p_task_id uuid,p_user_id uuid,p_task_version text,p_visible_ids uuid[],
  p_embedding extensions.vector(384),p_model_id text,p_text_version text,
  p_keywords text[],p_topic_tags text[],p_frameworks text[],p_domains text[],
  p_min_similarity double precision default 0.65,p_min_score double precision default 0.5,
  p_semantic_weight double precision default 0.75,p_keyword_weight double precision default 0.7)
returns table(resource_id uuid,similarity double precision,score double precision,
  lexical_score double precision,source_version text,title text,summary text,resource_type text,resource_updated_at timestamptz)
language plpgsql stable security invoker set search_path='' as $$
begin
  if p_embedding is null or extensions.vector_dims(p_embedding) <> 384
    or extensions.vector_norm(p_embedding) <= 0 or p_model_id is distinct from 'gte-small'
    or p_text_version is distinct from 'skilltrack-v1-chunk400-mean-l2'
    or p_keywords is null or p_topic_tags is null or p_frameworks is null or p_domains is null
    or p_min_similarity is null or p_min_score is null or p_semantic_weight is null or p_keyword_weight is null
    or not (p_min_similarity between 0 and 1 and p_min_score between 0 and 1
      and p_semantic_weight between 0 and 1 and p_keyword_weight between 0 and 1) then
    raise exception 'Invalid search configuration or vector' using errcode='22023';
  end if;
  if not exists(select 1 from public.recommendation_load_owned_task(p_task_id,p_user_id) t
    where t.is_stalled and t.source_version=p_task_version) then return; end if;
  return query
  -- Exact search over the eligible set is deliberate at the initial marketplace
  -- scale. ANN oversampling followed by filtering could starve the top three.
  with eligible as materialized (
    select e.*,r.title,r.summary,r.resource_type,r.resource_updated_at from public.resource_embeddings e join public.recommendation_index_sources r
      on r.resource_id=e.resource_id and r.source_version=e.indexed_version
    where e.status='ready' and e.resource_id=any(p_visible_ids) and e.model_id=p_model_id and e.text_version=p_text_version
      and (cardinality(p_domains)=0 or cardinality(e.domains)=0 or e.domains && p_domains)
      and (cardinality(p_frameworks)=0 or cardinality(e.frameworks)=0 or e.frameworks && p_frameworks)
  ), measured as (
    select e.resource_id,e.source_version,e.title,e.summary,e.resource_type,e.resource_updated_at,e.frameworks,
      greatest(-1.0,least(1.0,1-(e.embedding operator(extensions.<=>) p_embedding)))::double precision sim,
      (p_keyword_weight*public.recommendation_jaccard(p_keywords,e.keywords)+
        (1-p_keyword_weight)*public.recommendation_jaccard(p_topic_tags,e.topic_tags)) lex
    from eligible e
  ), ranked as (
    select m.*,p_semantic_weight*m.sim+(1-p_semantic_weight)*m.lex rank_score from measured m
    where m.sim>=p_min_similarity and
      ((cardinality(p_frameworks)>0 and cardinality(m.frameworks)>0) or m.lex>0)
  )
  select r.resource_id,r.sim,r.rank_score,r.lex,r.source_version,r.title,r.summary,r.resource_type,r.resource_updated_at from ranked r
  where r.rank_score>=p_min_score order by r.rank_score desc,r.sim desc,r.resource_id limit 3;
end $$;


-- No authenticated access to embedding rows, transcripts, or backend RPCs.
-- The Edge Function resolves visible IDs using its USER client/RLS before ranking.
do $$ declare fn record; begin
  for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('enqueue_resource_embedding','queue_resource_embedding_after_analysis',
      'backfill_resource_embeddings','claim_resource_embedding','complete_resource_embedding','fail_resource_embedding',
      'recommendation_load_owned_task','recommendation_jaccard','match_resource_embeddings')
  loop execute format('revoke all on function %s from public,anon,authenticated',fn.signature);
    execute format('grant execute on function %s to service_role',fn.signature); end loop;
end $$;
notify pgrst,'reload schema';
commit;
