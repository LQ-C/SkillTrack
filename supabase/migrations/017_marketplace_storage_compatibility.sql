-- Apply after the canonical combined schema or equivalent reviewed schema.
-- Existing attachment rows require the explicit backfill in the integration guide.
begin;
do $$ begin
 if to_regprocedure('public.can_read_mentor_resource(uuid,text,boolean)') is null
    or to_regclass('public.resource_extractions') is null then
   raise exception 'Reconcile canonical marketplace and SkillTrack schemas first';
 end if;
end $$;
alter table public.learning_resources drop constraint resource_link;
alter table public.learning_resources add constraint resource_link check (
 case when attachment_path is not null then
   (external_url = '' or (public.valid_resource_link(external_url)
     and public.resource_analysis_storage_key(external_url) = 'mentor-reading-files/' || attachment_path))
   and ((kind='Reading' and attachment_path ~ ('^'||author_id::text||'/[0-9a-f]{32}\.(pdf|png|jpg|jpeg)$'))
     or (kind='Video' and attachment_path ~ ('^'||author_id::text||'/[0-9a-f]{32}\.mp4$')))
 else
   (kind='Guide' and char_length(trim(body))>=20 and (external_url='' or public.valid_resource_link(external_url)))
   or (kind in ('Video','Reading') and public.valid_resource_link(external_url))
 end
);
create or replace function public.is_pdf_resource(p_resource jsonb)
returns boolean language sql stable security invoker set search_path='' as $$
 select coalesce(p_resource->>'kind'='Reading' and not public.is_image_resource(p_resource)
   and public.resource_analysis_storage_key(p_resource->>'external_url') ~* '^(marketplace-documents|mentor-reading-files)/.+\.pdf$',false)
$$;

create or replace function public.enqueue_discovered_extraction(p_resource_id uuid,p_external_url text,p_storage_bucket text,p_storage_path text,p_allow_draft boolean default false)
returns uuid language plpgsql security invoker set search_path='' as $$
declare resource public.learning_resources%rowtype; object storage.objects%rowtype; version text; result uuid; kind text;
begin
 select * into resource from public.learning_resources r where r.id=p_resource_id
  and r.external_url=p_external_url and not r.moderation_hidden
  and (r.status='published' or (p_allow_draft and r.status='draft')) for share;
 if not found or public.resource_analysis_storage_key(p_external_url) is distinct from p_storage_bucket||'/'||p_storage_path then return null; end if;
 if resource.kind='Video' then kind:='video_transcript';
 elsif public.is_pdf_resource(to_jsonb(resource)) and p_storage_bucket in ('marketplace-documents','mentor-reading-files') then kind:='pdf_text';
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
notify pgrst,'reload schema';
commit;
