-- Apply after 013_resource_extractions.sql. Backend-only image processing.
-- No new tables, marketplace kinds, public buckets, or copied image bytes.
begin;
alter table public.resource_extractions drop constraint resource_extractions_extraction_type_check;
alter table public.resource_extractions add constraint resource_extractions_extraction_type_check
  check(extraction_type in ('video_transcript','pdf_text','image_description'));

-- This classifies only a resource's primary file, never a thumbnail/avatar.
-- Metadata is a discovery hint; the Edge Function verifies the actual bytes.
create function public.is_image_resource(p_resource jsonb)
returns boolean language sql stable security invoker set search_path='' as $$
 select coalesce(p_resource->>'kind'='Reading' and (
   public.resource_analysis_storage_key(p_resource->>'external_url') ~* '\.(png|jpe?g|gif|webp|bmp|svg|heic)$'
   or exists(select 1 from storage.objects o
     where o.bucket_id||'/'||o.name=public.resource_analysis_storage_key(p_resource->>'external_url')
       and lower(o.metadata->>'mimetype') like 'image/%')),false)
$$;

create or replace function public.is_pdf_resource(p_resource jsonb)
returns boolean language sql stable security invoker set search_path='' as $$
 select coalesce(p_resource->>'kind'='Reading' and not public.is_image_resource(p_resource)
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
    and ((r.kind='Video' and t.extraction_type='video_transcript') or (public.is_pdf_resource(to_jsonb(r)) and t.extraction_type='pdf_text') or (public.is_image_resource(to_jsonb(r)) and t.extraction_type='image_description')) and r.moderation_hidden=false
    and r.status in ('draft','published') and t.status='ready';
$$;

create or replace function public.resource_analysis_candidates(p_resource_id uuid,p_allow_draft boolean)
returns table(resource_id uuid,transcript_id uuid,source_file_id text,source_version text,content_version text)
language sql stable security invoker set search_path=public,pg_temp as $$
  select r.id,t.id,t.source_file_id,t.source_version,
    public.resource_analysis_version(to_jsonb(r),to_jsonb(t))
  from public.learning_resources r
  left join public.video_transcripts t on (r.kind='Video' or (public.is_pdf_resource(to_jsonb(r)) or public.is_image_resource(to_jsonb(r)))) and t.resource_id=r.id::text
    and t.status='ready'
    and t.storage_bucket||'/'||t.storage_path=public.resource_analysis_storage_key(r.external_url)
    and exists(select 1 from public.read_ready_resource_extraction(r.id,r.external_url,t.storage_bucket,t.storage_path) current_source where current_source.id=t.id)
  where (p_resource_id is null or r.id=p_resource_id) and not r.moderation_hidden
    and (r.status='published' or (p_allow_draft and p_resource_id is not null and r.status='draft'))
    and (((r.kind='Video' or (public.is_pdf_resource(to_jsonb(r)) or public.is_image_resource(to_jsonb(r)))) and t.id is not null)
      or (r.kind<>'Video' and not (public.is_pdf_resource(to_jsonb(r)) or public.is_image_resource(to_jsonb(r))) and nullif(btrim(r.body),'') is not null));
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
  if resource.kind='Video' or (public.is_pdf_resource(to_jsonb(resource)) or public.is_image_resource(to_jsonb(resource))) then
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
select r.id resource_id,r.title,r.summary,concat_ws(' ',case when public.is_image_resource(to_jsonb(r)) then t.transcript_text end,r.summary,r.category) description,
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


-- Discovery and claim share one transaction. Only committed Storage objects are
-- queued. The project URL and bucket come from backend configuration, not users.
create function public.claim_resource_image(
 p_project_url text,p_bucket text,p_draft_resource_id uuid default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare work public.resource_extractions%rowtype; resource jsonb; mime text; etag text;
begin
 if p_project_url !~ '^https://[a-zA-Z0-9.-]+(:[0-9]+)?/?$'
   or p_project_url is null or p_bucket is null or p_bucket !~ '^[a-zA-Z0-9_-]{1,100}$'
   or p_bucket='task-attachments' then
   raise exception 'Invalid image configuration' using errcode='22023';
 end if;
 insert into public.resource_extractions(resource_id,source_file_id,source_version,storage_bucket,storage_path,extraction_type)
 select r.id::text,o.id::text,v.version,o.bucket_id,o.name,'image_description'
 from public.learning_resources r join storage.objects o
   on public.resource_analysis_storage_key(r.external_url)=o.bucket_id||'/'||o.name
 cross join lateral(select coalesce(nullif(to_jsonb(o)->>'version',''),nullif(o.metadata->>'eTag',''),
   nullif(o.metadata->>'etag',''),extract(epoch from o.updated_at)::text) version) v
 where public.is_image_resource(to_jsonb(r)) and not r.moderation_hidden
   and ((p_draft_resource_id is null and r.status='published') or (r.id=p_draft_resource_id and r.status='draft'))
   and split_part(r.external_url,'/storage/v1/object/',1)=rtrim(p_project_url,'/')
   and o.bucket_id=p_bucket and v.version is not null
   and not exists(select 1 from public.resource_extractions e where e.resource_id=r.id::text
     and e.source_file_id=o.id::text and e.source_version=v.version)
 order by r.id limit 25
 on conflict(resource_id,source_file_id,source_version) do nothing;

 update public.resource_extractions set status='failed',claim_token=null,lease_expires_at=null,
   error_code='lease_expired',updated_at=clock_timestamp()
 where extraction_type='image_description' and status='processing'
   and lease_expires_at<=clock_timestamp() and attempt_count>=3;

 select e.* into work from public.resource_extractions e
 join public.learning_resources r on r.id::text=e.resource_id
 join storage.objects o on o.bucket_id=e.storage_bucket and o.name=e.storage_path
 where e.extraction_type='image_description' and public.is_image_resource(to_jsonb(r))
   and not r.moderation_hidden
   and ((p_draft_resource_id is null and r.status='published') or (r.id=p_draft_resource_id and r.status='draft'))
   and split_part(r.external_url,'/storage/v1/object/',1)=rtrim(p_project_url,'/')
   and public.resource_analysis_storage_key(r.external_url)=o.bucket_id||'/'||o.name
   and o.bucket_id=p_bucket and o.id::text=e.source_file_id
   and coalesce(nullif(to_jsonb(o)->>'version',''),nullif(o.metadata->>'eTag',''),
     nullif(o.metadata->>'etag',''),extract(epoch from o.updated_at)::text)=e.source_version
   and e.attempt_count<3 and ((e.status='pending' and e.next_attempt_at<=clock_timestamp())
     or (e.status='processing' and e.lease_expires_at<=clock_timestamp()))
 order by e.created_at,e.id limit 1 for update of e skip locked;
 if not found then return null; end if;
 update public.resource_extractions set status='processing',attempt_count=attempt_count+1,
   claim_token=gen_random_uuid(),lease_expires_at=clock_timestamp()+interval '180 seconds',
   error_code=null,updated_at=clock_timestamp() where id=work.id returning * into work;
 select to_jsonb(r) into resource from public.learning_resources r where r.id::text=work.resource_id;
 select o.metadata->>'mimetype',coalesce(o.metadata->>'eTag',o.metadata->>'etag') into mime,etag from storage.objects o
   where o.id::text=work.source_file_id and o.bucket_id=work.storage_bucket and o.name=work.storage_path;
 return to_jsonb(work)||jsonb_build_object('resource',resource,'mime_type',mime,'object_etag',etag);
end $$;

-- Description + labels + analysis provenance + embedding enqueue commit together.
-- The ready trigger creates the existing analysis receipt; no second Gemini call.
create function public.complete_resource_image(
 p_extraction_id uuid,p_claim_token uuid,p_resource jsonb,p_description text,
 p_keywords text[],p_topic_tags text[])
returns boolean language plpgsql security invoker set search_path='' as $$
declare work public.resource_extractions%rowtype; job_id uuid; token uuid:=gen_random_uuid();
begin
 if p_description is null or length(btrim(p_description)) not between 1 and 4000
   or p_description ~ '[[:cntrl:]]' then raise exception 'Invalid image description' using errcode='22023'; end if;
 select * into work from public.resource_extractions where id=p_extraction_id for update;
 if not found or work.extraction_type<>'image_description' or p_claim_token is null
   or work.claim_token is distinct from p_claim_token then return false; end if;
 -- On a lost-response retry, never rewrite the previously completed version.
 if work.status='ready' then return true; end if;
 if work.status<>'processing' or work.lease_expires_at<=clock_timestamp() then return false; end if;
 if p_resource->>'id' is distinct from work.resource_id then return false; end if;
 -- save_resource_analysis below locks/rechecks the current resource and Storage
 -- identity/version. An exception rolls this update and its trigger back too.
 update public.resource_extractions set status='ready',extracted_text=btrim(p_description),
   language=null,segments='[]',lease_expires_at=null,error_code=null,updated_at=clock_timestamp()
 where id=work.id returning * into work;
 job_id:=public.enqueue_resource_analysis(work.resource_id::uuid,p_resource->>'status'='draft');
 if job_id is null then raise exception 'Image source changed' using errcode='40001'; end if;
 update public.resource_analysis_jobs set status='processing',claim_token=token,
   lease_expires_at=clock_timestamp()+interval '180 seconds',attempt_count=attempt_count+1
 where id=job_id and status='pending';
 if not found then raise exception 'Image analysis claim changed' using errcode='40001'; end if;
 perform public.complete_resource_analysis_job(job_id,token,p_resource,to_jsonb(work),p_keywords,p_topic_tags);
 return true;
end $$;

create function public.fail_resource_image(
 p_extraction_id uuid,p_claim_token uuid,p_error_code text,p_retry_after_seconds integer default 60)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if p_error_code is null or p_error_code not in ('image_invalid','image_mime_mismatch',
   'image_unsupported','image_too_large','image_download_failed','image_configuration_invalid',
   'source_replaced','resource_changed','gemini_response_invalid','gemini_rate_limited','gemini_unavailable',
   'gemini_not_configured','analysis_timeout','analysis_failed') then
   raise exception 'Invalid image failure code' using errcode='22023';
 end if;
 update public.resource_extractions set
   status=case when attempt_count>=3 or p_error_code in ('image_invalid','image_mime_mismatch',
     'image_unsupported','image_too_large','image_configuration_invalid','source_replaced') then 'failed' else 'pending' end,
   claim_token=null,lease_expires_at=null,error_code=p_error_code,
   next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(60,least(86400,coalesce(p_retry_after_seconds,60)),attempt_count*120)),
   updated_at=clock_timestamp()
 where id=p_extraction_id and extraction_type='image_description' and status='processing'
   and claim_token=p_claim_token and lease_expires_at>clock_timestamp();
 return found;
end $$;

revoke all on function public.is_image_resource(jsonb) from public,anon,authenticated;
revoke all on function public.claim_resource_image(text,text,uuid) from public,anon,authenticated;
revoke all on function public.complete_resource_image(uuid,uuid,jsonb,text,text[],text[]) from public,anon,authenticated;
revoke all on function public.fail_resource_image(uuid,uuid,text,integer) from public,anon,authenticated;
grant execute on function public.is_image_resource(jsonb) to service_role;
grant execute on function public.claim_resource_image(text,text,uuid) to service_role;
grant execute on function public.complete_resource_image(uuid,uuid,jsonb,text,text[],text[]) to service_role;
grant execute on function public.fail_resource_image(uuid,uuid,text,integer) to service_role;
-- All replaced functions/views retain existing grants. RLS remains enabled.
notify pgrst,'reload schema';
commit;
