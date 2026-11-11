-- Apply after 006_resource_analysis_queue.sql (007 scheduler is unchanged).
-- No new tables. Preserve historical queue rows and the existing RLS/grants.
begin;
alter table public.resource_analysis_jobs
  alter column transcript_id drop not null,
  alter column source_file_id drop not null,
  alter column source_version drop not null,
  add column content_version text;
-- Legacy rows have no metadata snapshot. Retain them without claiming that
-- their old analysis represents today's metadata; backfill current content once.
update public.resource_analysis_jobs set content_version='legacy:'||id;
alter table public.resource_analysis_jobs alter column content_version set not null;
-- PostgreSQL truncates generated constraint names; identify only the two
-- superseded unique constraints by their exact column lists.
do $$
declare old_constraint record;
begin
  for old_constraint in select c.conname from pg_constraint c
    where c.conrelid='public.resource_analysis_jobs'::regclass and c.contype='u'
      and (select array_agg(a.attname::text order by k.ord)
        from unnest(c.conkey) with ordinality k(attnum,ord)
        join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum)
        in (array['resource_id','source_file_id','source_version'],array['transcript_id'])
  loop execute format('alter table public.resource_analysis_jobs drop constraint %I',old_constraint.conname); end loop;
end $$;
alter table public.resource_analysis_jobs
  add constraint resource_analysis_jobs_content_unique unique(resource_id,content_version),
  add constraint resource_analysis_jobs_source_check check(
    (transcript_id is null and source_file_id is null and source_version is null)
    or (transcript_id is not null and source_file_id is not null and source_version is not null));

-- A content fingerprint, not a credential. Ignore incidental timestamps and
-- moderation/status transitions; the worker and completion separately authorize them.
create function public.resource_analysis_version(p_resource jsonb,p_transcript jsonb)
returns text language sql immutable security invoker set search_path=public,pg_temp as $$
  select encode(sha256(convert_to(jsonb_build_array(
    p_resource->'id',p_resource->'author_id',p_resource->'title',p_resource->'summary',
    p_resource->'category',p_resource->'body',p_resource->'tags',p_resource->'kind',
    p_resource->'external_url',p_transcript->'id',p_transcript->'source_file_id',
    p_transcript->'source_version',p_transcript->'transcript_text')::text,'UTF8')),'hex');
$$;

-- Candidate matching only. The Edge Function still enforces the configured
-- project/bucket allowlist before reading text or calling Gemini. Never fetch a URL.
create function public.resource_analysis_storage_key(p_url text)
returns text language plpgsql immutable strict security invoker set search_path=public,pg_temp as $$
declare encoded text; bytes bytea:=''::bytea; pos integer:=1; ch text;
begin
  encoded:=substring(p_url from '^https://[^/?#@]+/storage/v1/object/(?:public|authenticated)/([^?#]+)$');
  if encoded is null then return null; end if;
  while pos<=length(encoded) loop
    ch:=substr(encoded,pos,1);
    if ch='%' then
      bytes:=bytes||decode(substr(encoded,pos+1,2),'hex');pos:=pos+3;
    else bytes:=bytes||convert_to(ch,'UTF8');pos:=pos+1;
    end if;
  end loop;
  return convert_from(bytes,'UTF8');
exception when others then return null;
end $$;

create function public.resource_analysis_candidates(p_resource_id uuid,p_allow_draft boolean)
returns table(resource_id uuid,transcript_id uuid,source_file_id text,source_version text,content_version text)
language sql stable security invoker set search_path=public,pg_temp as $$
  select r.id,t.id,t.source_file_id,t.source_version,
    public.resource_analysis_version(to_jsonb(r),to_jsonb(t))
  from public.learning_resources r
  left join public.video_transcripts t on r.kind='Video' and t.resource_id=r.id::text
    and t.status='ready'
    and t.storage_bucket||'/'||t.storage_path=public.resource_analysis_storage_key(r.external_url)
    and exists(select 1 from public.read_ready_video_transcript(r.id,r.external_url,t.storage_bucket,t.storage_path) current_source where current_source.id=t.id)
  where (p_resource_id is null or r.id=p_resource_id) and not r.moderation_hidden
    and (r.status='published' or (p_allow_draft and p_resource_id is not null and r.status='draft'))
    and ((r.kind='Video' and t.id is not null)
      or (r.kind<>'Video' and nullif(btrim(r.body),'') is not null));
$$;

create function public.enqueue_resource_analysis(p_resource_id uuid,p_allow_draft boolean default false)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare source record; result uuid;
begin
  select * into source from public.resource_analysis_candidates(p_resource_id,p_allow_draft);
  if not found then return null; end if;
  insert into public.resource_analysis_jobs(resource_id,transcript_id,source_file_id,source_version,content_version,allow_draft)
    values(source.resource_id,source.transcript_id,source.source_file_id,source.source_version,source.content_version,p_allow_draft)
  on conflict(resource_id,content_version) do nothing returning id into result;
  if result is null then
    -- A -> B -> A needs another analysis only if B has actually replaced the
    -- saved index. Do not reset failed jobs or ordinary duplicate completions.
    update public.resource_analysis_jobs j set status='pending',attempt_count=0,
      claim_token=null,lease_expires_at=null,next_attempt_at=clock_timestamp(),
      error_code=null,updated_at=clock_timestamp(),allow_draft=p_allow_draft
    where j.resource_id=source.resource_id and j.content_version=source.content_version and j.status='ready'
      and exists(select 1 from public.resource_analysis_jobs newer where newer.resource_id=j.resource_id
        and newer.status='ready' and newer.content_version<>j.content_version and newer.updated_at>j.updated_at)
    returning id into result;
    if result is null then
      select id into result from public.resource_analysis_jobs
        where resource_id=source.resource_id and content_version=source.content_version;
    end if;
  end if;
  return result;
end $$;

-- Preserve the original trigger/RPC contract for transcript completion.
create or replace function public.enqueue_video_analysis(p_transcript_id uuid,p_allow_draft boolean default false)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare resource_uuid uuid;
begin
  select r.id into resource_uuid from public.video_transcripts t
    join public.learning_resources r on r.id::text=t.resource_id
    join lateral public.resource_analysis_candidates(r.id,p_allow_draft) candidate on candidate.transcript_id=t.id
    where t.id=p_transcript_id;
  if resource_uuid is null then return null; end if;
  return public.enqueue_resource_analysis(resource_uuid,p_allow_draft);
end $$;

create or replace function public.enqueue_ready_resource_analysis(
  p_resource_id uuid default null,p_allow_draft boolean default false,p_limit integer default 25)
returns integer language plpgsql security invoker set search_path=public,pg_temp as $$
declare source record; queued integer:=0;
begin
  if p_limit is null or p_limit not between 1 and 100 or (p_allow_draft and p_resource_id is null) then
    raise exception 'Invalid analysis backfill request' using errcode='22023';
  end if;
  for source in select c.resource_id from public.resource_analysis_candidates(p_resource_id,p_allow_draft) c
    left join public.resource_analysis_jobs j on j.resource_id=c.resource_id and j.content_version=c.content_version
    where j.id is null or (j.status='ready' and exists(select 1 from public.resource_analysis_jobs newer
      where newer.resource_id=j.resource_id and newer.status='ready' and newer.content_version<>j.content_version and newer.updated_at>j.updated_at))
    order by c.resource_id limit p_limit
  loop
    if public.enqueue_resource_analysis(source.resource_id,p_allow_draft) is not null then queued:=queued+1; end if;
  end loop;
  return queued;
end $$;

-- Only this trigger crosses the client/backend boundary: callers cannot provide
-- a target ID, author, transcript or allow_draft. Resource writes still use RLS.
create function public.queue_saved_resource_analysis()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='UPDATE' and public.resource_analysis_version(to_jsonb(old),null)=public.resource_analysis_version(to_jsonb(new),null)
    and old.status is not distinct from new.status and old.moderation_hidden is not distinct from new.moderation_hidden then
    return new;
  end if;
  perform public.enqueue_resource_analysis(new.id,false);
  return new;
end $$;
create trigger saved_resource_analysis after insert or update on public.learning_resources
  for each row execute function public.queue_saved_resource_analysis();

create or replace function public.complete_resource_analysis_job(
  p_job_id uuid,p_claim_token uuid,p_resource jsonb,p_transcript jsonb,p_keywords text[],p_topic_tags text[])
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare job public.resource_analysis_jobs%rowtype; resource public.learning_resources%rowtype; saved jsonb;
begin
  select * into job from public.resource_analysis_jobs where id=p_job_id for update;
  if not found or p_claim_token is null or job.claim_token is distinct from p_claim_token
    or job.status<>'processing' or job.lease_expires_at<=clock_timestamp() then
    raise exception 'Analysis claim lost' using errcode='40001';
  end if;
  select * into resource from public.learning_resources where id=job.resource_id for update;
  if not found or resource.moderation_hidden
    or not (resource.status='published' or (job.allow_draft and resource.status='draft')) then
    raise exception 'Resource ineligible' using errcode='42501';
  end if;
  if (p_resource->>'id')::uuid is distinct from job.resource_id
    or public.resource_analysis_version(p_resource,p_transcript) is distinct from job.content_version
    or (p_transcript->>'id')::uuid is distinct from job.transcript_id
    or p_transcript->>'source_file_id' is distinct from job.source_file_id
    or p_transcript->>'source_version' is distinct from job.source_version then
    raise exception 'Analysis source changed' using errcode='40001';
  end if;
  saved:=public.save_resource_analysis(resource.author_id,p_resource,p_transcript,p_keywords,p_topic_tags);
  update public.resource_analysis_jobs set status='ready',lease_expires_at=null,error_code=null,updated_at=clock_timestamp() where id=job.id;
  return saved;
end $$;

revoke all on function public.resource_analysis_version(jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.resource_analysis_storage_key(text) from public,anon,authenticated;
revoke all on function public.resource_analysis_candidates(uuid,boolean) from public,anon,authenticated;
revoke all on function public.enqueue_resource_analysis(uuid,boolean) from public,anon,authenticated;
revoke all on function public.queue_saved_resource_analysis() from public,anon,authenticated;
grant execute on function public.resource_analysis_version(jsonb,jsonb) to service_role;
grant execute on function public.resource_analysis_storage_key(text) to service_role;
grant execute on function public.resource_analysis_candidates(uuid,boolean) to service_role;
grant execute on function public.enqueue_resource_analysis(uuid,boolean) to service_role;
-- Replaced functions retain their service_role-only grants from 006.
commit;
