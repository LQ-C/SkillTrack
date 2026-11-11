-- Verified live resource_index.resource_id is UUID PK/FK to learning_resources.
-- No table, column or RLS policy changes. Install before the updated Edge Function.
begin;
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
  if resource.kind='Video' then
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
      or transcript.transcript_text is distinct from p_transcript->>'transcript_text'
      or not exists(select 1 from public.read_ready_video_transcript(resource.id,
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
revoke all on function public.save_resource_analysis(uuid,jsonb,jsonb,text[],text[])
  from public,anon,authenticated;
grant execute on function public.save_resource_analysis(uuid,jsonb,jsonb,text[],text[])
  to service_role;
commit;
