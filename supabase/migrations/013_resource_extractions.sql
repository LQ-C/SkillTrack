-- Apply after 001-012 and the real marketplace schema. Transactional rename,
-- no copied/deleted content and no resource_id cast. Keep compatibility until
-- all old worker/Edge callers have been retired. Requires PostgreSQL 15+.
begin;
lock table public.video_transcripts in access exclusive mode;
alter table public.video_transcripts rename to resource_extractions;
alter table public.resource_extractions rename column transcript_text to extracted_text;
alter table public.resource_extractions add column extraction_type text not null
  default 'video_transcript' check(extraction_type in ('video_transcript','pdf_text'));
-- Preserve old projection/column order, including future optional columns.
do $$ declare columns text; begin
 select string_agg(case when attname='extracted_text' then 'extracted_text as transcript_text'
   else quote_ident(attname) end,',' order by attnum) into columns
 from pg_attribute where attrelid='public.resource_extractions'::regclass
   and attnum>0 and not attisdropped and attname<>'extraction_type';
 execute 'create view public.video_transcripts with (security_invoker=true) as select '||columns||' from public.resource_extractions';
end $$;
revoke all on public.video_transcripts from public,anon,authenticated;
-- SELECT FOR SHARE in deployed analysis/notification functions also needs UPDATE.
grant select,update on public.video_transcripts to service_role;
-- Existing FK dependencies and ready-text/RLS constraints follow the table rename.
-- Rename this SETOF function so its table row type stays valid after the rename.
alter function public.read_ready_video_transcript(uuid,text,text,text) rename to read_ready_resource_extraction;

create function public.is_pdf_resource(p_resource jsonb)
returns boolean language sql immutable security invoker set search_path='' as $$
 select coalesce(p_resource->>'kind'='Reading'
   and public.resource_analysis_storage_key(p_resource->>'external_url') ~* '^marketplace-documents/.+\.pdf$',false)
$$;


create or replace function public.read_ready_resource_extraction(
  p_resource_id uuid, p_external_url text, p_storage_bucket text, p_storage_path text)
returns setof public.resource_extractions language sql stable security invoker
set search_path = public, storage, pg_temp as $$
  select t.* from public.learning_resources r
  join storage.objects o on o.bucket_id=p_storage_bucket and o.name=p_storage_path
  join public.resource_extractions t on t.resource_id=r.id::text
    and t.source_file_id=o.id::text
    and t.source_version=coalesce(nullif(to_jsonb(o)->>'version',''),
      nullif(o.metadata->>'eTag',''),nullif(o.metadata->>'etag',''),
      extract(epoch from o.updated_at)::text)
    and t.storage_bucket=o.bucket_id and t.storage_path=o.name
  where r.id=p_resource_id and r.external_url=p_external_url
    and public.resource_analysis_storage_key(r.external_url)=p_storage_bucket||'/'||p_storage_path
    and ((r.kind='Video' and t.extraction_type='video_transcript') or (public.is_pdf_resource(to_jsonb(r)) and t.extraction_type='pdf_text')) and r.moderation_hidden=false
    and r.status in ('draft','published') and t.status='ready';
$$;

create or replace function public.read_ready_video_transcript(
 p_resource_id uuid,p_external_url text,p_storage_bucket text,p_storage_path text)
returns setof public.video_transcripts language sql stable security invoker set search_path='' as $$
 select v.* from public.video_transcripts v join public.read_ready_resource_extraction(
 p_resource_id,p_external_url,p_storage_bucket,p_storage_path) e on e.id=v.id
 where e.extraction_type='video_transcript'
$$;

create or replace function public.enqueue_video_transcription(
  p_resource_id text, p_source_file_id text, p_source_version text,
  p_storage_bucket text, p_storage_path text)
returns uuid language plpgsql security invoker
set search_path = public, storage, pg_temp as $$
declare v_id uuid; v_existing public.resource_extractions%rowtype;
begin
  if p_resource_id is null or length(btrim(p_resource_id)) not between 1 and 256
    or p_source_file_id is null or length(btrim(p_source_file_id)) not between 1 and 256
    or p_source_version is null or length(btrim(p_source_version)) not between 1 and 256
    or p_storage_bucket is null or length(btrim(p_storage_bucket)) not between 1 and 100
    or p_storage_bucket like '%/%'
    or p_storage_path is null or length(btrim(p_storage_path)) not between 1 and 1024
    or exists (select 1 from unnest(string_to_array(p_storage_path, '/')) as parts(segment)
      where segment in ('', '.', '..')) then
    raise exception 'Invalid transcription source' using errcode = '22023';
  end if;

  -- The confirmed resource PK is UUID. Keep legacy stored text IDs intact.
  -- Backend callers must verify the resource/file association before enqueue.
  perform 1 from public.learning_resources r
    where r.id::text = p_resource_id and r.kind = 'Video'
      and r.moderation_hidden = false and r.status in ('draft','published') for share;
  if not found then
    raise exception 'Eligible video resource not found' using errcode = 'P0002';
  end if;
  perform 1 from storage.objects o
    where o.bucket_id = p_storage_bucket and o.name = p_storage_path for share;
  if not found then
    raise exception 'Video Storage object not found' using errcode = 'P0002';
  end if;

  insert into public.resource_extractions
    (resource_id, source_file_id, source_version, storage_bucket, storage_path)
  values (p_resource_id, p_source_file_id, p_source_version,
          p_storage_bucket, p_storage_path)
  on conflict (resource_id, source_file_id, source_version) do nothing
  returning id into v_id;
  if v_id is not null then return v_id; end if;

  select * into v_existing from public.resource_extractions
  where resource_id = p_resource_id and source_file_id = p_source_file_id
    and source_version = p_source_version;
  if v_existing.storage_bucket is distinct from p_storage_bucket
    or v_existing.storage_path is distinct from p_storage_path then
    raise exception 'Source version already enqueued for a different object'
      using errcode = '23505';
  end if;
  return v_existing.id;
end;
$$;

create or replace function public.claim_resource_extraction(p_lease_seconds integer default 900, p_type text default null)
returns jsonb language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.resource_extractions%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then
    raise exception 'Invalid lease duration' using errcode = '22023';
  end if;

  if p_type is not null and p_type not in ('video_transcript','pdf_text') then raise exception 'Invalid extraction type'; end if;
  -- Expired final attempts become terminal rather than remaining processing.
  update public.resource_extractions set status = 'failed',
    claim_token = null, lease_expires_at = null, error_code = 'lease_expired',
    updated_at = v_now
  where status = 'processing' and lease_expires_at <= v_now
    and attempt_count >= 3;

  select * into v_job from public.resource_extractions e
  where exists (select 1 from public.learning_resources r join storage.objects o
    on o.bucket_id=e.storage_bucket and o.name=e.storage_path
    where r.id::text=e.resource_id and not r.moderation_hidden and r.status in ('draft','published')
      and ((r.kind='Video' and e.extraction_type='video_transcript') or (public.is_pdf_resource(to_jsonb(r)) and e.extraction_type='pdf_text'))
      and public.resource_analysis_storage_key(r.external_url)=o.bucket_id||'/'||o.name
      and o.id::text=e.source_file_id
      and coalesce(nullif(to_jsonb(o)->>'version',''),nullif(o.metadata->>'eTag',''),
        nullif(o.metadata->>'etag',''),extract(epoch from o.updated_at)::text)=e.source_version)
    and (p_type is null or extraction_type=p_type) and attempt_count < 3 and (
    (status = 'pending' and next_attempt_at <= v_now) or
    (status = 'processing' and lease_expires_at <= v_now))
  order by created_at, id limit 1 for update skip locked;
  if not found then return null; end if;

  update public.resource_extractions set status = 'processing',
    attempt_count = attempt_count + 1, claim_token = gen_random_uuid(),
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    error_code = null, updated_at = v_now
  where id = v_job.id returning * into v_job;

  return jsonb_build_object(
    'extraction_type', v_job.extraction_type, 'id', v_job.id, 'claim_token', v_job.claim_token,
    'resource_id', v_job.resource_id,
    'source_file_id', v_job.source_file_id,
    'source_version', v_job.source_version,
    'storage_bucket', v_job.storage_bucket,
    'storage_path', v_job.storage_path);
end;
$$;

create or replace function public.renew_resource_extraction(
  p_extraction_id uuid, p_claim_token uuid, p_lease_seconds integer default 900)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_now timestamptz := clock_timestamp();
begin
  if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then
    raise exception 'Invalid lease duration' using errcode = '22023';
  end if;
  update public.resource_extractions set
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    updated_at = v_now
  where id = p_extraction_id and claim_token = p_claim_token
    and status = 'processing' and lease_expires_at > v_now;
  return found;
end;
$$;

create or replace function public.complete_resource_extraction(
  p_extraction_id uuid, p_claim_token uuid, p_extracted_text text,
  p_language text, p_segments jsonb)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.resource_extractions%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_extracted_text is null or length(btrim(p_extracted_text)) = 0
    or p_segments is null or jsonb_typeof(p_segments) <> 'array'
    or length(coalesce(p_language, '')) > 20 then
    raise exception 'Invalid transcript' using errcode = '22023';
  end if;
  select * into v_job from public.resource_extractions
  where id = p_extraction_id for update;
  if not found or p_claim_token is null or v_job.claim_token is distinct from p_claim_token then
    return false;
  end if;
  -- Reject a worker whose file/resource changed during download/extraction.
  perform 1 from public.learning_resources r join storage.objects o
    on o.bucket_id=v_job.storage_bucket and o.name=v_job.storage_path
  where r.id::text=v_job.resource_id and not r.moderation_hidden and r.status in ('draft','published')
    and ((r.kind='Video' and v_job.extraction_type='video_transcript')
      or (public.is_pdf_resource(to_jsonb(r)) and v_job.extraction_type='pdf_text'))
    and public.resource_analysis_storage_key(r.external_url)=o.bucket_id||'/'||o.name
    and o.id::text=v_job.source_file_id
    and coalesce(nullif(to_jsonb(o)->>'version',''),nullif(o.metadata->>'eTag',''),
      nullif(o.metadata->>'etag',''),extract(epoch from o.updated_at)::text)=v_job.source_version
    for share of r,o;
  if not found then return false; end if;
  if v_job.status = 'ready' then
    return true;
  end if;
  if v_job.status <> 'processing' or v_job.lease_expires_at <= v_now then
    return false;
  end if;

  update public.resource_extractions set status = 'ready',
    extracted_text = p_extracted_text, language = p_language, segments = p_segments,
    lease_expires_at = null, updated_at = v_now
  where id = p_extraction_id;
  return true;
end;
$$;

create or replace function public.fail_resource_extraction(
  p_extraction_id uuid, p_claim_token uuid, p_error_code text)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.resource_extractions%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_error_code is null or p_error_code not in
    ('download_failed', 'transcription_failed', 'save_failed', 'pdf_invalid', 'pdf_encrypted', 'pdf_empty', 'pdf_ocr_failed', 'pdf_extraction_failed', 'source_replaced') then
    raise exception 'Invalid failure code' using errcode = '22023';
  end if;
  select * into v_job from public.resource_extractions
  where id = p_extraction_id for update;
  if not found or v_job.status <> 'processing'
    or v_job.claim_token is distinct from p_claim_token
    or v_job.lease_expires_at <= v_now then
    return false;
  end if;
  update public.resource_extractions set
    status = case when attempt_count >= 3 then 'failed' else 'pending' end,
    claim_token = null, lease_expires_at = null,
    next_attempt_at = v_now + make_interval(mins => least(30, attempt_count * 2)),
    error_code = p_error_code, updated_at = v_now
  where id = p_extraction_id;
  return true;
end;
$$;

create or replace function public.claim_video_transcript(p_lease_seconds integer default 900)
returns jsonb language sql security invoker set search_path='' as $$
 select public.claim_resource_extraction(p_lease_seconds,'video_transcript') $$;
create or replace function public.renew_video_transcript(p_transcript_id uuid,p_claim_token uuid,p_lease_seconds integer default 900)
returns boolean language sql security invoker set search_path='' as $$
 select public.renew_resource_extraction(p_transcript_id,p_claim_token,p_lease_seconds) $$;
create or replace function public.complete_video_transcript(p_transcript_id uuid,p_claim_token uuid,p_transcript_text text,p_language text,p_segments jsonb)
returns boolean language sql security invoker set search_path='' as $$
 select public.complete_resource_extraction(p_transcript_id,p_claim_token,p_transcript_text,p_language,p_segments) $$;
create or replace function public.fail_video_transcript(p_transcript_id uuid,p_claim_token uuid,p_error_code text)
returns boolean language sql security invoker set search_path='' as $$
 select public.fail_resource_extraction(p_transcript_id,p_claim_token,p_error_code) $$;


create function public.resource_extraction_candidates(p_limit integer default 25,p_after_id uuid default null,p_draft_resource_id uuid default null)
returns table(id uuid,external_url text,kind text) language plpgsql security invoker set search_path='' as $$
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid batch size'; end if;
 return query select r.id,r.external_url,r.kind::text from public.learning_resources r
 where not r.moderation_hidden and (r.kind='Video' or public.is_pdf_resource(to_jsonb(r)))
 and ((p_draft_resource_id is null and r.status='published' and (p_after_id is null or r.id>p_after_id))
 or (p_draft_resource_id=r.id and r.status='draft')) order by r.id limit p_limit;
end $$;
create function public.enqueue_discovered_extraction(p_resource_id uuid,p_external_url text,p_storage_bucket text,p_storage_path text,p_allow_draft boolean default false)
returns uuid language plpgsql security invoker set search_path='' as $$
declare resource public.learning_resources%rowtype; object storage.objects%rowtype; version text; result uuid; kind text;
begin
 select * into resource from public.learning_resources r where r.id=p_resource_id
  and r.external_url=p_external_url and not r.moderation_hidden
  and (r.status='published' or (p_allow_draft and r.status='draft')) for share;
 if not found or public.resource_analysis_storage_key(p_external_url) is distinct from p_storage_bucket||'/'||p_storage_path then return null; end if;
 if resource.kind='Video' then kind:='video_transcript';
 elsif public.is_pdf_resource(to_jsonb(resource)) and p_storage_bucket='marketplace-documents' then kind:='pdf_text';
 else return null; end if;
 select * into object from storage.objects o where o.bucket_id=p_storage_bucket and o.name=p_storage_path for share;
 if not found then return null; end if;
 version:=coalesce(nullif(to_jsonb(object)->>'version',''),nullif(object.metadata->>'eTag',''),nullif(object.metadata->>'etag',''),extract(epoch from object.updated_at)::text);
 if version is null then return null; end if;
 insert into public.resource_extractions(resource_id,source_file_id,source_version,storage_bucket,storage_path,extraction_type)
 values(p_resource_id::text,object.id::text,version,p_storage_bucket,p_storage_path,kind)
 on conflict(resource_id,source_file_id,source_version) do nothing returning id into result;
 if result is null then select id into result from public.resource_extractions where resource_id=p_resource_id::text and source_file_id=object.id::text and source_version=version; end if;
 return result;
end $$;

create or replace function public.resource_analysis_version(p_resource jsonb,p_transcript jsonb)
returns text language sql immutable security invoker set search_path=public,pg_temp as $$
  select encode(sha256(convert_to(jsonb_build_array(
    p_resource->'id',p_resource->'author_id',p_resource->'title',p_resource->'summary',
    p_resource->'category',p_resource->'body',p_resource->'tags',p_resource->'kind',
    p_resource->'external_url',p_transcript->'id',p_transcript->'source_file_id',
    p_transcript->'source_version',coalesce(p_transcript->'extracted_text',p_transcript->'transcript_text'))::text,'UTF8')),'hex');
$$;

create or replace function public.resource_analysis_candidates(p_resource_id uuid,p_allow_draft boolean)
returns table(resource_id uuid,transcript_id uuid,source_file_id text,source_version text,content_version text)
language sql stable security invoker set search_path=public,pg_temp as $$
  select r.id,t.id,t.source_file_id,t.source_version,
    public.resource_analysis_version(to_jsonb(r),to_jsonb(t))
  from public.learning_resources r
  left join public.video_transcripts t on (r.kind='Video' or public.is_pdf_resource(to_jsonb(r))) and t.resource_id=r.id::text
    and t.status='ready'
    and t.storage_bucket||'/'||t.storage_path=public.resource_analysis_storage_key(r.external_url)
    and exists(select 1 from public.read_ready_resource_extraction(r.id,r.external_url,t.storage_bucket,t.storage_path) current_source where current_source.id=t.id)
  where (p_resource_id is null or r.id=p_resource_id) and not r.moderation_hidden
    and (r.status='published' or (p_allow_draft and p_resource_id is not null and r.status='draft'))
    and (((r.kind='Video' or public.is_pdf_resource(to_jsonb(r))) and t.id is not null)
      or (r.kind<>'Video' and not public.is_pdf_resource(to_jsonb(r)) and nullif(btrim(r.body),'') is not null));
$$;

create or replace function public.save_resource_analysis(
  p_user_id uuid, p_resource jsonb, p_transcript jsonb,
  p_keywords text[], p_topic_tags text[])
returns jsonb language plpgsql security invoker
set search_path = public, storage, pg_temp as $$
declare
  resource public.learning_resources%rowtype;
  transcript public.video_transcripts%rowtype;
  saved public.resource_index%rowtype;
begin
  if p_user_id is null or p_resource is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  select * into resource from public.learning_resources
    where id=(p_resource->>'id')::uuid for update;
  if not found or resource.author_id<>p_user_id or resource.moderation_hidden
      or resource.status not in ('draft','published') then
    raise exception 'Resource analysis forbidden' using errcode='42501';
  end if;
  -- Compare all source fields, with timestamp normalization for REST encoding.
  if (to_jsonb(resource)-'created_at'-'updated_at') is distinct from
       (p_resource-'created_at'-'updated_at')
      or resource.updated_at is distinct from (p_resource->>'updated_at')::timestamptz
      or resource.created_at is distinct from (p_resource->>'created_at')::timestamptz then
    raise exception 'Resource changed' using errcode='40001';
  end if;
  if resource.kind='Video' or public.is_pdf_resource(to_jsonb(resource)) then
    if p_transcript is null then
      raise exception 'Current transcript required' using errcode='40001';
    end if;
    -- Block replacement while checking the current source and saving the index.
    perform 1 from storage.objects o where o.bucket_id=p_transcript->>'storage_bucket'
      and o.name=p_transcript->>'storage_path' for share;
    if not found then raise exception 'Video changed' using errcode='40001'; end if;
    select * into transcript from public.video_transcripts
      where id=(p_transcript->>'id')::uuid for share;
    if not found or transcript.status<>'ready'
      or transcript.transcript_text is distinct from coalesce(p_transcript->>'extracted_text',p_transcript->>'transcript_text')
      or not exists(select 1 from public.read_ready_resource_extraction(resource.id,
        resource.external_url,transcript.storage_bucket,transcript.storage_path) t
        where t.id=transcript.id and t.source_file_id=p_transcript->>'source_file_id'
          and t.source_version=p_transcript->>'source_version') then
      raise exception 'Video changed' using errcode='40001';
    end if;
  elsif p_transcript is not null then
    raise exception 'Resource kind changed' using errcode='40001';
  end if;
  if p_keywords is null or p_topic_tags is null
    or cardinality(p_keywords)>20 or cardinality(p_topic_tags)>8
    or exists(select 1 from unnest(p_keywords || p_topic_tags) x
      where x is null or length(btrim(x)) not between 1 and 80 or x ~ '[[:cntrl:]]') then
    raise exception 'Invalid resource analysis' using errcode='22023';
  end if;
  insert into public.resource_index(resource_id,keywords,topic_tags,analysed_at)
    values(resource.id,p_keywords,p_topic_tags,clock_timestamp())
  on conflict(resource_id) do update set keywords=excluded.keywords,
    topic_tags=excluded.topic_tags,analysed_at=excluded.analysed_at
  returning * into saved;
  return to_jsonb(saved);
end;
$$;

create or replace view public.recommendation_index_sources as
select r.id resource_id,r.title,r.summary,concat_ws(' ',r.summary,r.category) description,
  r.kind resource_type,case when public.is_pdf_resource(to_jsonb(r)) then t.transcript_text else r.body end pdf_text,
  case when r.kind='Video' then coalesce(t.transcript_text,'') else '' end transcript,
  i.keywords,i.topic_tags,r.updated_at resource_updated_at,
  encode(sha256(convert_to(jsonb_build_array(c.content_version,i.keywords,i.topic_tags)::text,'UTF8')),'hex') source_version
from public.learning_resources r
join public.resource_analysis_candidates(null,false) c on c.resource_id=r.id
join public.resource_index i on i.resource_id=r.id
join public.resource_analysis_jobs j on j.resource_id=r.id and j.content_version=c.content_version
  and j.status='ready' and j.updated_at>=i.analysed_at
left join public.video_transcripts t on t.id=c.transcript_id
where r.status='published' and r.moderation_hidden=false;


revoke all on function public.is_pdf_resource(jsonb) from public,anon,authenticated;
grant execute on function public.is_pdf_resource(jsonb) to service_role;

revoke all on function public.read_ready_resource_extraction(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.read_ready_resource_extraction(uuid,text,text,text) to service_role;

revoke all on function public.read_ready_video_transcript(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.read_ready_video_transcript(uuid,text,text,text) to service_role;

revoke all on function public.claim_resource_extraction(integer,text) from public,anon,authenticated;
grant execute on function public.claim_resource_extraction(integer,text) to service_role;

revoke all on function public.renew_resource_extraction(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.renew_resource_extraction(uuid,uuid,integer) to service_role;

revoke all on function public.complete_resource_extraction(uuid,uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.complete_resource_extraction(uuid,uuid,text,text,jsonb) to service_role;

revoke all on function public.fail_resource_extraction(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.fail_resource_extraction(uuid,uuid,text) to service_role;

revoke all on function public.resource_extraction_candidates(integer,uuid,uuid) from public,anon,authenticated;
grant execute on function public.resource_extraction_candidates(integer,uuid,uuid) to service_role;

revoke all on function public.enqueue_discovered_extraction(uuid,text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.enqueue_discovered_extraction(uuid,text,text,text,boolean) to service_role;

notify pgrst,'reload schema';
commit;
