-- Requires 004_simplify_video_transcripts.sql and 005_save_resource_analysis.sql.
-- Backend work queue only. Transcription engine and resource_index are unchanged.
begin;
create table public.resource_analysis_jobs (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.learning_resources(id) on delete cascade,
  transcript_id uuid not null references public.video_transcripts(id) on delete cascade,
  source_file_id text not null,
  source_version text not null,
  allow_draft boolean not null default false,
  status text not null default 'pending' check(status in ('pending','processing','ready','failed','skipped')),
  attempt_count integer not null default 0 check(attempt_count>=0),
  claim_token uuid,
  lease_expires_at timestamptz,
  next_attempt_at timestamptz not null default now(),
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(resource_id,source_file_id,source_version),
  unique(transcript_id),
  check((status='processing')=(lease_expires_at is not null)),
  check(status<>'processing' or claim_token is not null)
);
create index resource_analysis_jobs_claim_idx on public.resource_analysis_jobs(status,next_attempt_at,lease_expires_at,created_at);
alter table public.resource_analysis_jobs enable row level security;
revoke all on public.resource_analysis_jobs from public,anon,authenticated;
grant select,insert,update on public.resource_analysis_jobs to service_role;

create function public.enqueue_video_analysis(p_transcript_id uuid,p_allow_draft boolean default false)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare source record; result uuid;
begin
  select t.*,r.id as resource_uuid into source from public.video_transcripts t
  join public.learning_resources r on r.id::text=t.resource_id
  where t.id=p_transcript_id and t.status='ready' and r.kind='Video'
    and not r.moderation_hidden
    and (r.status='published' or (p_allow_draft and r.status='draft'))
    and exists(select 1 from public.read_ready_video_transcript(r.id,r.external_url,t.storage_bucket,t.storage_path) current_source
      where current_source.id=t.id);
  if not found then return null; end if;
  insert into public.resource_analysis_jobs(resource_id,transcript_id,source_file_id,source_version,allow_draft)
    values(source.resource_uuid,source.id,source.source_file_id,source.source_version,p_allow_draft)
  on conflict(resource_id,source_file_id,source_version) do nothing returning id into result;
  if result is null then
    select id into result from public.resource_analysis_jobs
      where resource_id=source.resource_uuid and source_file_id=source.source_file_id and source_version=source.source_version;
  end if;
  return result;
end $$;

create function public.queue_ready_transcript_analysis()
returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
begin
  if tg_op='UPDATE' and old.status='ready' then return new; end if;
  if new.status='ready' then perform public.enqueue_video_analysis(new.id,false); end if;
  return new;
end $$;
create trigger video_transcript_ready_analysis
  after insert or update of status on public.video_transcripts
  for each row execute function public.queue_ready_transcript_analysis();

-- Periodic bounded backfill also handles videos published after transcription.
-- Draft scanning is impossible without an explicit UUID and allow_draft flag.
create function public.enqueue_ready_resource_analysis(
  p_resource_id uuid default null,p_allow_draft boolean default false,p_limit integer default 25)
returns integer language plpgsql security invoker set search_path=public,pg_temp as $$
declare source record; queued integer:=0;
begin
  if p_limit is null or p_limit not between 1 and 100 or (p_allow_draft and p_resource_id is null) then
    raise exception 'Invalid analysis backfill request' using errcode='22023';
  end if;
  for source in select t.id from public.video_transcripts t
    join public.learning_resources r on r.id::text=t.resource_id
    where t.status='ready' and r.kind='Video' and not r.moderation_hidden
      and (p_resource_id is null or r.id=p_resource_id)
      and (r.status='published' or (p_allow_draft and r.status='draft'))
      and not exists(select 1 from public.resource_analysis_jobs j where j.transcript_id=t.id)
      and exists(select 1 from public.read_ready_video_transcript(r.id,r.external_url,t.storage_bucket,t.storage_path) current_source where current_source.id=t.id)
    order by t.created_at,t.id limit p_limit
  loop
    if public.enqueue_video_analysis(source.id,p_allow_draft) is not null then queued:=queued+1; end if;
  end loop;
  return queued;
end $$;

create function public.claim_resource_analysis_job(p_resource_id uuid default null)
returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare job public.resource_analysis_jobs%rowtype; moment timestamptz:=clock_timestamp();
begin
  update public.resource_analysis_jobs set status='failed',claim_token=null,lease_expires_at=null,
    error_code='lease_expired',updated_at=moment
    where status='processing' and lease_expires_at<=moment and attempt_count>=3;
  select * into job from public.resource_analysis_jobs
    where (p_resource_id is null or resource_id=p_resource_id) and attempt_count<3
      and ((status='pending' and next_attempt_at<=moment) or (status='processing' and lease_expires_at<=moment))
    order by created_at,id limit 1 for update skip locked;
  if not found then return null; end if;
  update public.resource_analysis_jobs set status='processing',attempt_count=attempt_count+1,
    claim_token=gen_random_uuid(),lease_expires_at=moment+interval '180 seconds',updated_at=moment,error_code=null
    where id=job.id returning * into job;
  return to_jsonb(job);
end $$;

-- Index upsert and queue completion commit together. No lost-response gap.
create function public.complete_resource_analysis_job(
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
  if not found or resource.moderation_hidden or resource.kind<>'Video'
    or not (resource.status='published' or (job.allow_draft and resource.status='draft')) then
    raise exception 'Resource ineligible' using errcode='42501';
  end if;
  if p_transcript is null or (p_transcript->>'id')::uuid is distinct from job.transcript_id
    or p_transcript->>'source_file_id' is distinct from job.source_file_id
    or p_transcript->>'source_version' is distinct from job.source_version
    or (p_resource->>'id')::uuid is distinct from job.resource_id then
    raise exception 'Analysis source changed' using errcode='40001';
  end if;
  saved:=public.save_resource_analysis(resource.author_id,p_resource,p_transcript,p_keywords,p_topic_tags);
  update public.resource_analysis_jobs set status='ready',lease_expires_at=null,error_code=null,updated_at=clock_timestamp()
    where id=job.id;
  return saved;
end $$;

create function public.fail_resource_analysis_job(
  p_job_id uuid,p_claim_token uuid,p_error_code text,p_skip boolean default false,p_retry_after_seconds integer default 60)
returns boolean language plpgsql security invoker set search_path=public,pg_temp as $$
begin
  if p_error_code is null or p_error_code not in
    ('source_replaced','resource_ineligible','analysis_failed','gemini_rate_limited','gemini_unavailable',
     'gemini_response_invalid','analysis_timeout','resource_changed','resource_backend_unavailable',
     'video_transcript_not_ready','video_storage_reference_unsupported','resource_content_too_large','resource_content_empty')
    or p_retry_after_seconds is null or p_retry_after_seconds not between 1 and 86400 then
    raise exception 'Invalid analysis failure' using errcode='22023';
  end if;
  update public.resource_analysis_jobs set
    status=case when p_skip then 'skipped' when attempt_count>=3 then 'failed' else 'pending' end,
    claim_token=null,lease_expires_at=null,error_code=p_error_code,updated_at=clock_timestamp(),
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(p_retry_after_seconds,60*attempt_count))
    where id=p_job_id and claim_token=p_claim_token and status='processing' and lease_expires_at>clock_timestamp();
  return found;
end $$;

revoke all on function public.enqueue_video_analysis(uuid,boolean) from public,anon,authenticated;
revoke all on function public.queue_ready_transcript_analysis() from public,anon,authenticated;
revoke all on function public.enqueue_ready_resource_analysis(uuid,boolean,integer) from public,anon,authenticated;
revoke all on function public.claim_resource_analysis_job(uuid) from public,anon,authenticated;
revoke all on function public.complete_resource_analysis_job(uuid,uuid,jsonb,jsonb,text[],text[]) from public,anon,authenticated;
revoke all on function public.fail_resource_analysis_job(uuid,uuid,text,boolean,integer) from public,anon,authenticated;
grant execute on function public.enqueue_video_analysis(uuid,boolean) to service_role;
grant execute on function public.queue_ready_transcript_analysis() to service_role;
grant execute on function public.enqueue_ready_resource_analysis(uuid,boolean,integer) to service_role;
grant execute on function public.claim_resource_analysis_job(uuid) to service_role;
grant execute on function public.complete_resource_analysis_job(uuid,uuid,jsonb,jsonb,text[],text[]) to service_role;
grant execute on function public.fail_resource_analysis_job(uuid,uuid,text,boolean,integer) to service_role;
commit;
