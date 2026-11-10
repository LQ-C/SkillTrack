-- Apply after 001_video_transcription.sql. Backend only; no new tables.
-- Resource contract confirmed by the project owner: UUID id, text kind/status/
-- external_url and boolean moderation_hidden. The base DDL is not in this repo.
begin;

create function public.video_transcription_candidates(
  p_limit integer default 25, p_after_id uuid default null,
  p_draft_resource_id uuid default null)
returns table(id uuid, external_url text)
language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'Invalid discovery batch size' using errcode = '22023';
  end if;
  return query
    select r.id, r.external_url from public.learning_resources r
    where r.kind = 'Video' and r.moderation_hidden = false
      and r.external_url is not null
      and ((p_draft_resource_id is null and r.status = 'published'
            and (p_after_id is null or r.id > p_after_id))
        or (p_draft_resource_id is not null and r.id = p_draft_resource_id
            and r.status = 'draft'))
    order by r.id limit p_limit;
end;
$$;

create function public.enqueue_discovered_video(
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
        and t.source_file_id = v_object.id::text and t.source_version = v_version) then
    return null;
  end if;
  select j.id into v_job_id from public.video_transcription_jobs j
    where j.resource_id = p_resource_id::text
      and j.source_file_id = v_object.id::text and j.source_version = v_version;
  if found then return v_job_id; end if;
  return public.enqueue_video_transcription(
    p_resource_id::text, v_object.id::text, v_version,
    p_storage_bucket, p_storage_path);
end;
$$;

revoke all on function public.video_transcription_candidates(integer,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.enqueue_discovered_video(uuid,text,text,text,boolean)
  from public, anon, authenticated;
grant execute on function public.video_transcription_candidates(integer,uuid,uuid)
  to service_role;
grant execute on function public.enqueue_discovered_video(uuid,text,text,text,boolean)
  to service_role;
-- SECURITY INVOKER intentionally retains the server role's existing table access.
commit;
