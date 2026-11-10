-- Apply after 001 and 002. Pause workers and take a backup before applying.
-- The transaction preserves existing transcript IDs and active claim tokens.
begin;
lock table public.video_transcription_jobs, public.video_transcripts in access exclusive mode;
do $$ begin
  if exists(select 1 from public.video_transcription_jobs j
    left join public.video_transcripts t on t.job_id=j.id
    where (j.status='ready' and t.id is null) or (t.id is not null and
      (j.status<>'ready' or (t.resource_id,t.source_file_id,t.source_version)
        is distinct from (j.resource_id,j.source_file_id,j.source_version)))) then
    raise exception 'Inconsistent transcription data; reconcile before migration';
  end if;
end $$;
alter table public.video_transcripts
  drop constraint video_transcripts_job_id_fkey,
  alter column transcript_text drop not null,
  add column storage_bucket text, add column storage_path text,
  add column status text, add column attempt_count integer, add column max_attempts integer,
  add column claim_token uuid, add column lease_expires_at timestamptz,
  add column next_attempt_at timestamptz, add column error_code text,
  add column updated_at timestamptz, add column completed_at timestamptz,
  add column queued_at timestamptz;
-- Preserve transcript created_at; queued_at preserves the original queue timestamp.
update public.video_transcripts t set
  storage_bucket=j.storage_bucket,storage_path=j.storage_path,status=j.status,
  attempt_count=j.attempt_count,max_attempts=j.max_attempts,claim_token=j.claim_token,
  lease_expires_at=j.lease_expires_at,next_attempt_at=j.next_attempt_at,error_code=j.error_code,
  updated_at=j.updated_at,completed_at=j.completed_at,queued_at=j.created_at
from public.video_transcription_jobs j where t.job_id=j.id;
insert into public.video_transcripts
  (job_id,resource_id,source_file_id,source_version,storage_bucket,storage_path,status,
   attempt_count,max_attempts,claim_token,lease_expires_at,next_attempt_at,error_code,
   created_at,updated_at,completed_at,queued_at)
select j.id,j.resource_id,j.source_file_id,j.source_version,j.storage_bucket,j.storage_path,
  j.status,j.attempt_count,j.max_attempts,j.claim_token,j.lease_expires_at,j.next_attempt_at,
  j.error_code,j.created_at,j.updated_at,j.completed_at,j.created_at
from public.video_transcription_jobs j
where not exists(select 1 from public.video_transcripts t where t.job_id=j.id);
-- Validate all copied work-state fields before removing the source table.
do $$ begin
  if exists(
    select id,resource_id,source_file_id,source_version,storage_bucket,storage_path,status,
      attempt_count,max_attempts,claim_token,lease_expires_at,next_attempt_at,error_code,
      created_at,updated_at,completed_at from public.video_transcription_jobs
    except
    select job_id,resource_id,source_file_id,source_version,storage_bucket,storage_path,status,
      attempt_count,max_attempts,claim_token,lease_expires_at,next_attempt_at,error_code,
      queued_at,updated_at,completed_at from public.video_transcripts
  ) or (select count(*) from public.video_transcripts) <>
       (select count(*) from public.video_transcription_jobs) then
    raise exception 'Transcription migration verification failed';
  end if;
end $$;
alter table public.video_transcripts
  alter column job_id set default gen_random_uuid(),
  alter column storage_bucket set not null, alter column storage_path set not null,
  alter column status set default 'pending', alter column status set not null,
  alter column attempt_count set default 0, alter column attempt_count set not null,
  alter column max_attempts set default 3, alter column max_attempts set not null,
  alter column next_attempt_at set default now(), alter column next_attempt_at set not null,
  alter column updated_at set default now(), alter column updated_at set not null,
  alter column queued_at set default now(), alter column queued_at set not null,
  add constraint video_transcripts_status_check check(status in ('pending','processing','ready','failed')),
  add constraint video_transcripts_attempts_check check(attempt_count>=0 and max_attempts between 1 and 10),
  add constraint video_transcripts_lease_check check((status='processing')=(lease_expires_at is not null)),
  add constraint video_transcripts_claim_check check(status<>'processing' or claim_token is not null),
  add constraint video_transcripts_ready_check check(status<>'ready' or
    (transcript_text is not null and length(btrim(transcript_text))>0)),
  add constraint video_transcripts_source_check check
    (length(btrim(resource_id)) between 1 and 256 and length(btrim(source_file_id)) between 1 and 256
     and length(btrim(source_version)) between 1 and 256
     and length(btrim(storage_bucket)) between 1 and 100 and length(btrim(storage_path)) between 1 and 1024);
comment on column public.video_transcripts.job_id is
  'Stable work identifier for legacy RPC compatibility; no separate jobs table.';
create index video_transcripts_claim_idx on public.video_transcripts
  (status,next_attempt_at,lease_expires_at,queued_at);

create or replace function public.enqueue_video_transcription(
  p_resource_id text, p_source_file_id text, p_source_version text,
  p_storage_bucket text, p_storage_path text)
returns uuid language plpgsql security invoker
set search_path = public, storage, pg_temp as $$
declare v_id uuid; v_existing public.video_transcripts%rowtype;
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

  insert into public.video_transcripts
    (resource_id, source_file_id, source_version, storage_bucket, storage_path)
  values (p_resource_id, p_source_file_id, p_source_version,
          p_storage_bucket, p_storage_path)
  on conflict (resource_id, source_file_id, source_version) do nothing
  returning job_id into v_id;
  if v_id is not null then return v_id; end if;

  select * into v_existing from public.video_transcripts
  where resource_id = p_resource_id and source_file_id = p_source_file_id
    and source_version = p_source_version;
  if v_existing.storage_bucket is distinct from p_storage_bucket
    or v_existing.storage_path is distinct from p_storage_path then
    raise exception 'Source version already enqueued for a different object'
      using errcode = '23505';
  end if;
  return v_existing.job_id;
end;
$$;

create or replace function public.claim_transcription_job(p_lease_seconds integer default 900)
returns jsonb language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.video_transcripts%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then
    raise exception 'Invalid lease duration' using errcode = '22023';
  end if;

  -- Expired final attempts become terminal rather than remaining processing.
  update public.video_transcripts set status = 'failed',
    claim_token = null, lease_expires_at = null, error_code = 'lease_expired',
    updated_at = v_now
  where status = 'processing' and lease_expires_at <= v_now
    and attempt_count >= max_attempts;

  select * into v_job from public.video_transcripts
  where attempt_count < max_attempts and (
    (status = 'pending' and next_attempt_at <= v_now) or
    (status = 'processing' and lease_expires_at <= v_now))
  order by queued_at, id limit 1 for update skip locked;
  if not found then return null; end if;

  update public.video_transcripts set status = 'processing',
    attempt_count = attempt_count + 1, claim_token = gen_random_uuid(),
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    error_code = null, updated_at = v_now
  where job_id = v_job.job_id returning * into v_job;

  return jsonb_build_object(
    'job_id', v_job.job_id, 'transcript_id', v_job.id, 'claim_token', v_job.claim_token,
    'resource_id', v_job.resource_id,
    'source_file_id', v_job.source_file_id,
    'source_version', v_job.source_version,
    'storage_bucket', v_job.storage_bucket,
    'storage_path', v_job.storage_path);
end;
$$;

create or replace function public.renew_transcription_claim(
  p_job_id uuid, p_claim_token uuid, p_lease_seconds integer default 900)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_now timestamptz := clock_timestamp();
begin
  if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then
    raise exception 'Invalid lease duration' using errcode = '22023';
  end if;
  update public.video_transcripts set
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    updated_at = v_now
  where job_id = p_job_id and claim_token = p_claim_token
    and status = 'processing' and lease_expires_at > v_now;
  return found;
end;
$$;

create or replace function public.complete_transcription_job(
  p_job_id uuid, p_claim_token uuid, p_transcript_text text,
  p_language text, p_segments jsonb)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.video_transcripts%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_transcript_text is null or length(btrim(p_transcript_text)) = 0
    or p_segments is null or jsonb_typeof(p_segments) <> 'array'
    or length(coalesce(p_language, '')) > 20 then
    raise exception 'Invalid transcript' using errcode = '22023';
  end if;
  select * into v_job from public.video_transcripts
  where job_id = p_job_id for update;
  if not found or p_claim_token is null or v_job.claim_token is distinct from p_claim_token then
    return false;
  end if;
  if v_job.status = 'ready' then
    return exists(select 1 from public.video_transcripts where job_id = p_job_id);
  end if;
  if v_job.status <> 'processing' or v_job.lease_expires_at <= v_now then
    return false;
  end if;

  update public.video_transcripts set status = 'ready',
    transcript_text = p_transcript_text, language = p_language, segments = p_segments,
    lease_expires_at = null, completed_at = v_now, updated_at = v_now
  where job_id = p_job_id;
  return true;
end;
$$;

create or replace function public.fail_transcription_job(
  p_job_id uuid, p_claim_token uuid, p_error_code text)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.video_transcripts%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_error_code is null or p_error_code not in
    ('download_failed', 'transcription_failed', 'save_failed') then
    raise exception 'Invalid failure code' using errcode = '22023';
  end if;
  select * into v_job from public.video_transcripts
  where job_id = p_job_id for update;
  if not found or v_job.status <> 'processing'
    or v_job.claim_token is distinct from p_claim_token
    or v_job.lease_expires_at <= v_now then
    return false;
  end if;
  update public.video_transcripts set
    status = case when attempt_count >= max_attempts then 'failed' else 'pending' end,
    claim_token = null, lease_expires_at = null,
    next_attempt_at = v_now + make_interval(mins => least(30, attempt_count * 2)),
    error_code = p_error_code, updated_at = v_now
  where job_id = p_job_id;
  return true;
end;
$$;

create or replace function public.enqueue_discovered_video(
  p_resource_id uuid, p_external_url text, p_storage_bucket text,
  p_storage_path text, p_allow_draft boolean default false)
returns uuid language plpgsql security invoker
set search_path = public, storage, pg_temp as $$
declare
  v_object storage.objects%rowtype;
  v_version text;
  v_job_id uuid;
begin
  -- Recheck eligibility and the exact reference after candidate selection.
  -- The trusted worker validates the URL's project, bucket and stable endpoint.
  perform 1 from public.learning_resources r
    where r.id = p_resource_id and r.kind = 'Video'
      and r.moderation_hidden = false and r.external_url = p_external_url
      and (r.status = 'published' or (p_allow_draft and r.status = 'draft'))
    for share;
  if not found then return null; end if;

  select * into v_object from storage.objects o
    where o.bucket_id = p_storage_bucket and o.name = p_storage_path for share;
  if not found then return null; end if;
  -- Storage object identity is the fallback file ID. Prefer Storage's upload
  -- version; older Storage installations can use etag or last modification.
  v_version := coalesce(nullif(to_jsonb(v_object)->>'version', ''),
                        nullif(v_object.metadata->>'eTag', ''),
                        nullif(v_object.metadata->>'etag', ''),
                        extract(epoch from v_object.updated_at)::text);
  if v_version is null then return null; end if;

  if exists(select 1 from public.video_transcripts t
      where t.resource_id = p_resource_id::text
        and t.source_file_id = v_object.id::text and t.source_version = v_version
        and t.status = 'ready') then
    return null;
  end if;
  select j.job_id into v_job_id from public.video_transcripts j
    where j.resource_id = p_resource_id::text
      and j.source_file_id = v_object.id::text and j.source_version = v_version;
  if found then return v_job_id; end if;
  return public.enqueue_video_transcription(
    p_resource_id::text, v_object.id::text, v_version,
    p_storage_bucket, p_storage_path);
end;
$$;

-- Backend adapter must validate the URL and derive bucket/path from it using
-- the configured project/bucket allowlist; authorize the resource owner first.
create function public.read_ready_video_transcript(
  p_resource_id uuid, p_external_url text, p_storage_bucket text, p_storage_path text)
returns setof public.video_transcripts language sql stable security invoker
set search_path = public, storage, pg_temp as $$
  select t.* from public.learning_resources r
  join storage.objects o on o.bucket_id=p_storage_bucket and o.name=p_storage_path
  join public.video_transcripts t on t.resource_id=r.id::text
    and t.source_file_id=o.id::text
    and t.source_version=coalesce(nullif(to_jsonb(o)->>'version',''),
      nullif(o.metadata->>'eTag',''),nullif(o.metadata->>'etag',''),
      extract(epoch from o.updated_at)::text)
    and t.storage_bucket=o.bucket_id and t.storage_path=o.name
  where r.id=p_resource_id and r.external_url=p_external_url
    and r.kind='Video' and r.moderation_hidden=false
    and r.status in ('draft','published') and t.status='ready';
$$;
revoke all on function public.read_ready_video_transcript(uuid,text,text,text)
  from public,anon,authenticated;
grant execute on function public.read_ready_video_transcript(uuid,text,text,text) to service_role;
alter table public.video_transcripts enable row level security;
revoke all on public.video_transcripts from public,anon,authenticated;
grant select,insert,update on public.video_transcripts to service_role;
-- Existing RPC signatures retain service_role-only grants.
-- RESTRICT (no CASCADE) aborts the transaction for unknown external dependencies.
-- PL/pgSQL string bodies may not have catalog dependency edges. Fail closed
-- for any remaining stored routine referencing the old table as well.
do $$
declare dependencies text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into dependencies
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname not in ('pg_catalog','information_schema')
    and p.prosrc ~* '\mvideo_transcription_jobs\M';
  if dependencies is not null then
    raise exception 'Review old transcription table dependencies: %', dependencies;
  end if;
end $$;
drop table public.video_transcription_jobs;
commit;
