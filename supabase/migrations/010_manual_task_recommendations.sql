-- Apply after 009. No tables, task writes or marketplace policy changes.
begin;

create function public.recommendation_load_owned_task(p_task_id uuid,p_user_id uuid,p_mode text)
returns table(title text,description text,is_stalled boolean,source_version text)
language plpgsql stable security invoker set search_path='' as $$
begin
  if p_mode is null or p_mode not in ('automatic','manual') then
    raise exception 'Invalid recommendation mode' using errcode='22023';
  end if;
  return query
  select case when (p_mode='manual' or t.is_stalled) and t.status<>'completed' then t.title::text end,
    case when (p_mode='manual' or t.is_stalled) and t.status<>'completed' then coalesce(t.description,'') end,
    t.is_stalled and t.status<>'completed',
    encode(sha256(convert_to(jsonb_build_array(t.title,t.description,t.is_stalled,t.status)::text,'UTF8')),'hex')
  from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
  where t.id=p_task_id and p.owner_id=p_user_id and p.status='active' and not b.is_archived and not t.is_archived
    and (p_mode='automatic' or t.status<>'completed');
end
$$;

create function public.match_resource_embeddings(
  p_task_id uuid,p_user_id uuid,p_mode text,p_task_version text,p_visible_ids uuid[],
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
  if not exists(select 1 from public.recommendation_load_owned_task(p_task_id,p_user_id,p_mode) t
    where (p_mode='manual' or t.is_stalled) and t.source_version=p_task_version) then return; end if;
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


create or replace function public.recommendation_load_owned_task(p_task_id uuid,p_user_id uuid)
returns table(title text,description text,is_stalled boolean,source_version text)
language sql stable security invoker set search_path='' as $$
  select * from public.recommendation_load_owned_task(p_task_id,p_user_id,'automatic');
$$;
create or replace function public.match_resource_embeddings(
  p_task_id uuid,p_user_id uuid,p_task_version text,p_visible_ids uuid[],
  p_embedding extensions.vector(384),p_model_id text,p_text_version text,
  p_keywords text[],p_topic_tags text[],p_frameworks text[],p_domains text[],
  p_min_similarity double precision default 0.65,p_min_score double precision default 0.5,
  p_semantic_weight double precision default 0.75,p_keyword_weight double precision default 0.7)
returns table(resource_id uuid,similarity double precision,score double precision,
  lexical_score double precision,source_version text,title text,summary text,resource_type text,resource_updated_at timestamptz)
language sql stable security invoker set search_path='' as $$
  select * from public.match_resource_embeddings(p_task_id,p_user_id,'automatic',p_task_version,p_visible_ids,
    p_embedding,p_model_id,p_text_version,p_keywords,p_topic_tags,p_frameworks,p_domains,
    p_min_similarity,p_min_score,p_semantic_weight,p_keyword_weight);
$$;

do $$ declare fn record; begin
  for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('recommendation_load_owned_task','match_resource_embeddings')
  loop execute format('revoke all on function %s from public,anon,authenticated',fn.signature);
    execute format('grant execute on function %s to service_role',fn.signature); end loop;
end $$;
notify pgrst,'reload schema';
commit;
