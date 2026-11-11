-- Apply after 003. Stop all old worker processes before applying; restart the
-- updated worker afterwards. Existing transcript IDs/text and active tokens stay
-- intact, but old job-ID requests are retired. Expired leases remain recoverable.
begin;
lock table public.video_transcripts in access exclusive mode;
do $$ begin
  if to_regclass('public.video_transcription_jobs') is not null then
    raise exception 'Apply 003 and verify its data migration before 004';
  end if;
end $$;

-- RESTRICT prevents silently removing unknown database callers.
drop function public.claim_transcription_job(integer);
drop function public.renew_transcription_claim(uuid,uuid,integer);
drop function public.complete_transcription_job(uuid,uuid,text,text,jsonb);
drop function public.fail_transcription_job(uuid,uuid,text);

-- Fixed server policy: three attempts including the first attempt. Existing
-- terminal failures stay terminal. A pending row already at the limit must not
-- remain pending forever after a previous custom max_attempts policy.
update public.video_transcripts set status='failed', claim_token=null,
  lease_expires_at=null, error_code=coalesce(error_code,'attempt_limit_reached'),
  updated_at=clock_timestamp()
where status='pending' and attempt_count>=3;

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
  returning id into v_id;
  if v_id is not null then return v_id; end if;

  select * into v_existing from public.video_transcripts
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

create or replace function public.claim_video_transcript(p_lease_seconds integer default 900)
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
    and attempt_count >= 3;

  select * into v_job from public.video_transcripts
  where attempt_count < 3 and (
    (status = 'pending' and next_attempt_at <= v_now) or
    (status = 'processing' and lease_expires_at <= v_now))
  order by created_at, id limit 1 for update skip locked;
  if not found then return null; end if;

  update public.video_transcripts set status = 'processing',
    attempt_count = attempt_count + 1, claim_token = gen_random_uuid(),
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    error_code = null, updated_at = v_now
  where id = v_job.id returning * into v_job;

  return jsonb_build_object(
    'id', v_job.id, 'claim_token', v_job.claim_token,
    'resource_id', v_job.resource_id,
    'source_file_id', v_job.source_file_id,
    'source_version', v_job.source_version,
    'storage_bucket', v_job.storage_bucket,
    'storage_path', v_job.storage_path);
end;
$$;

create or replace function public.renew_video_transcript(
  p_transcript_id uuid, p_claim_token uuid, p_lease_seconds integer default 900)
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
  where id = p_transcript_id and claim_token = p_claim_token
    and status = 'processing' and lease_expires_at > v_now;
  return found;
end;
$$;

create or replace function public.complete_video_transcript(
  p_transcript_id uuid, p_claim_token uuid, p_transcript_text text,
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
  where id = p_transcript_id for update;
  if not found or p_claim_token is null or v_job.claim_token is distinct from p_claim_token then
    return false;
  end if;
  if v_job.status = 'ready' then
    return true;
  end if;
  if v_job.status <> 'processing' or v_job.lease_expires_at <= v_now then
    return false;
  end if;

  update public.video_transcripts set status = 'ready',
    transcript_text = p_transcript_text, language = p_language, segments = p_segments,
    lease_expires_at = null, updated_at = v_now
  where id = p_transcript_id;
  return true;
end;
$$;

create or replace function public.fail_video_transcript(
  p_transcript_id uuid, p_claim_token uuid, p_error_code text)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
declare v_job public.video_transcripts%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_error_code is null or p_error_code not in
    ('download_failed', 'transcription_failed', 'save_failed') then
    raise exception 'Invalid failure code' using errcode = '22023';
  end if;
  select * into v_job from public.video_transcripts
  where id = p_transcript_id for update;
  if not found or v_job.status <> 'processing'
    or v_job.claim_token is distinct from p_claim_token
    or v_job.lease_expires_at <= v_now then
    return false;
  end if;
  update public.video_transcripts set
    status = case when attempt_count >= 3 then 'failed' else 'pending' end,
    claim_token = null, lease_expires_at = null,
    next_attempt_at = v_now + make_interval(mins => least(30, attempt_count * 2)),
    error_code = p_error_code, updated_at = v_now
  where id = p_transcript_id;
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
  v_transcript_id uuid;
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
  select j.id into v_transcript_id from public.video_transcripts j
    where j.resource_id = p_resource_id::text
      and j.source_file_id = v_object.id::text and j.source_version = v_version;
  if found then return v_transcript_id; end if;
  return public.enqueue_video_transcription(
    p_resource_id::text, v_object.id::text, v_version,
    p_storage_bucket, p_storage_path);
end;
$$;

-- Catch untracked stored routine bodies as well as PostgreSQL dependencies.
-- Source-text inspection is conservative; review any reported routine manually.
do $$
declare dependencies text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into dependencies
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname not in ('pg_catalog','information_schema') and (
    p.prosrc ~* '\mvideo_transcription_jobs\M'
    or (p.prosrc ~* '\mvideo_transcripts\M'
        and p.prosrc ~* '\m(job_id|queued_at|completed_at|max_attempts)\M'));
  if dependencies is not null then
    raise exception 'Review transcription dependencies before removing columns: %', dependencies;
  end if;
end $$;

-- No CASCADE: dependent views or external FKs abort and roll back this migration.
drop index public.video_transcripts_claim_idx;
alter table public.video_transcripts
  drop column job_id, drop column queued_at, drop column completed_at,
  drop column max_attempts,
  add constraint video_transcripts_attempt_count_check check(attempt_count>=0);
create index video_transcripts_claim_idx on public.video_transcripts
  (status,next_attempt_at,lease_expires_at,created_at);

revoke all on function public.claim_video_transcript(integer) from public,anon,authenticated;
revoke all on function public.renew_video_transcript(uuid,uuid,integer) from public,anon,authenticated;
revoke all on function public.complete_video_transcript(uuid,uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.fail_video_transcript(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.claim_video_transcript(integer) to service_role;
grant execute on function public.renew_video_transcript(uuid,uuid,integer) to service_role;
grant execute on function public.complete_video_transcript(uuid,uuid,text,text,jsonb) to service_role;
grant execute on function public.fail_video_transcript(uuid,uuid,text) to service_role;
-- Existing table RLS and ready/nonempty-text constraints remain enforced.
commit;
