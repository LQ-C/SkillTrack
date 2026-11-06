-- LOCAL MIGRATION ONLY. Review the real marketplace schema and upload callback
-- before applying. Marketplace IDs are opaque text because that schema is absent.
-- Call enqueue_video_transcription only from a trusted backend AFTER both the
-- Storage upload and the resource/file record commit successfully.
begin;

create table public.video_transcription_jobs (
  id uuid primary key default gen_random_uuid(),
  resource_id text not null check (length(btrim(resource_id)) between 1 and 256),
  source_file_id text not null check (length(btrim(source_file_id)) between 1 and 256),
  source_version text not null check (length(btrim(source_version)) between 1 and 256),
  storage_bucket text not null check (length(btrim(storage_bucket)) between 1 and 100),
  storage_path text not null check (length(btrim(storage_path)) between 1 and 1024),
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'ready', 'failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 3 check (max_attempts between 1 and 10),
  claim_token uuid,
  lease_expires_at timestamptz,
  next_attempt_at timestamptz not null default now(),
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (resource_id, source_file_id, source_version),
  check ((status = 'processing') = (lease_expires_at is not null))
);

create index video_transcription_jobs_claim_idx
  on public.video_transcription_jobs(status, next_attempt_at, lease_expires_at, created_at);

create table public.video_transcripts (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null unique references public.video_transcription_jobs(id) on delete cascade,
  resource_id text not null,
  source_file_id text not null,
  source_version text not null,
  language text,
  transcript_text text not null check (length(btrim(transcript_text)) > 0),
  segments jsonb not null default '[]'::jsonb check (jsonb_typeof(segments) = 'array'),
  created_at timestamptz not null default now(),
  unique (resource_id, source_file_id, source_version)
);

-- No client-facing policy. Only the service role may call the RPCs below.
alter table public.video_transcription_jobs enable row level security;
alter table public.video_transcripts enable row level security;
revoke all on public.video_transcription_jobs, public.video_transcripts
  from public, anon, authenticated;
grant select, insert, update on public.video_transcription_jobs, public.video_transcripts
  to service_role;

create function public.enqueue_video_transcription(
  p_resource_id text, p_source_file_id text, p_source_version text,
  p_storage_bucket text, p_storage_path text)
returns uuid language plpgsql security invoker
set search_path = public, storage, pg_temp as $$
declare v_id uuid; v_existing public.video_transcription_jobs%rowtype;
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

  -- This confirms the uploaded object exists. The caller must also verify its
  -- link to the authorized marketplace resource; that schema is unavailable.
  if not exists (select 1 from storage.objects o
      where o.bucket_id = p_storage_bucket and o.name = p_storage_path) then
    raise exception 'Video Storage object not found' using errcode = 'P0002';
  end if;

  insert into public.video_transcription_jobs
    (resource_id, source_file_id, source_version, storage_bucket, storage_path)
  values (p_resource_id, p_source_file_id, p_source_version,
          p_storage_bucket, p_storage_path)
  on conflict (resource_id, source_file_id, source_version) do nothing
  returning id into v_id;
  if v_id is not null then return v_id; end if;

  select * into v_existing from public.video_transcription_jobs
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

create function public.claim_transcription_job(p_lease_seconds integer default 900)
returns jsonb language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.video_transcription_jobs%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then
    raise exception 'Invalid lease duration' using errcode = '22023';
  end if;

  -- Expired final attempts become terminal rather than remaining processing.
  update public.video_transcription_jobs set status = 'failed',
    claim_token = null, lease_expires_at = null, error_code = 'lease_expired',
    updated_at = v_now
  where status = 'processing' and lease_expires_at <= v_now
    and attempt_count >= max_attempts;

  select * into v_job from public.video_transcription_jobs
  where attempt_count < max_attempts and (
    (status = 'pending' and next_attempt_at <= v_now) or
    (status = 'processing' and lease_expires_at <= v_now))
  order by created_at, id limit 1 for update skip locked;
  if not found then return null; end if;

  update public.video_transcription_jobs set status = 'processing',
    attempt_count = attempt_count + 1, claim_token = gen_random_uuid(),
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    error_code = null, updated_at = v_now
  where id = v_job.id returning * into v_job;

  return jsonb_build_object(
    'job_id', v_job.id, 'claim_token', v_job.claim_token,
    'resource_id', v_job.resource_id,
    'source_file_id', v_job.source_file_id,
    'source_version', v_job.source_version,
    'storage_bucket', v_job.storage_bucket,
    'storage_path', v_job.storage_path);
end;
$$;

create function public.renew_transcription_claim(
  p_job_id uuid, p_claim_token uuid, p_lease_seconds integer default 900)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_now timestamptz := clock_timestamp();
begin
  if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then
    raise exception 'Invalid lease duration' using errcode = '22023';
  end if;
  update public.video_transcription_jobs set
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    updated_at = v_now
  where id = p_job_id and claim_token = p_claim_token
    and status = 'processing' and lease_expires_at > v_now;
  return found;
end;
$$;

create function public.complete_transcription_job(
  p_job_id uuid, p_claim_token uuid, p_transcript_text text,
  p_language text, p_segments jsonb)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.video_transcription_jobs%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_transcript_text is null or length(btrim(p_transcript_text)) = 0
    or p_segments is null or jsonb_typeof(p_segments) <> 'array'
    or length(coalesce(p_language, '')) > 20 then
    raise exception 'Invalid transcript' using errcode = '22023';
  end if;
  select * into v_job from public.video_transcription_jobs
  where id = p_job_id for update;
  if not found or v_job.claim_token is distinct from p_claim_token then
    return false;
  end if;
  if v_job.status = 'ready' then
    return exists(select 1 from public.video_transcripts where job_id = p_job_id);
  end if;
  if v_job.status <> 'processing' or v_job.lease_expires_at <= v_now then
    return false;
  end if;

  insert into public.video_transcripts
    (job_id, resource_id, source_file_id, source_version,
     language, transcript_text, segments)
  values (v_job.id, v_job.resource_id, v_job.source_file_id,
          v_job.source_version, p_language, p_transcript_text, p_segments);
  update public.video_transcription_jobs set status = 'ready',
    lease_expires_at = null, completed_at = v_now, updated_at = v_now
  where id = p_job_id;
  return true;
end;
$$;

create function public.fail_transcription_job(
  p_job_id uuid, p_claim_token uuid, p_error_code text)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.video_transcription_jobs%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_error_code is null or p_error_code not in
    ('download_failed', 'transcription_failed', 'save_failed') then
    raise exception 'Invalid failure code' using errcode = '22023';
  end if;
  select * into v_job from public.video_transcription_jobs
  where id = p_job_id for update;
  if not found or v_job.status <> 'processing'
    or v_job.claim_token is distinct from p_claim_token
    or v_job.lease_expires_at <= v_now then
    return false;
  end if;
  update public.video_transcription_jobs set
    status = case when attempt_count >= max_attempts then 'failed' else 'pending' end,
    claim_token = null, lease_expires_at = null,
    next_attempt_at = v_now + make_interval(mins => least(30, attempt_count * 2)),
    error_code = p_error_code, updated_at = v_now
  where id = p_job_id;
  return true;
end;
$$;

revoke all on function public.enqueue_video_transcription(text,text,text,text,text)
  from public, anon, authenticated;
revoke all on function public.claim_transcription_job(integer)
  from public, anon, authenticated;
revoke all on function public.renew_transcription_claim(uuid,uuid,integer)
  from public, anon, authenticated;
revoke all on function public.complete_transcription_job(uuid,uuid,text,text,jsonb)
  from public, anon, authenticated;
revoke all on function public.fail_transcription_job(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.enqueue_video_transcription(text,text,text,text,text)
  to service_role;
grant execute on function public.claim_transcription_job(integer) to service_role;
grant execute on function public.renew_transcription_claim(uuid,uuid,integer) to service_role;
grant execute on function public.complete_transcription_job(uuid,uuid,text,text,jsonb)
  to service_role;
grant execute on function public.fail_transcription_job(uuid,uuid,text) to service_role;
commit;
