-- Additive split after 017 or its equivalent canonical target schema.
-- PREPARED ONLY: run the read-only setup audit first. No file bytes/rows are moved.
begin;
do $$ begin
 if to_regprocedure('public.can_read_mentor_resource(uuid,text,boolean)') is null
    or to_regprocedure('public.resource_analysis_storage_key(text)') is null then
   raise exception 'Reconcile the canonical marketplace and analysis schema first';
 end if;
end $$;
-- Existing buckets are retained (including object IDs). Create only if missing.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('mentor-reading-files','mentor-reading-files',false,10485760,array['application/pdf','image/png','image/jpeg']),
 ('mentor-video-files','mentor-video-files',false,52428800,array['video/mp4'])
on conflict(id) do nothing;
-- These restrictions affect future uploads; existing videos in reading remain readable.
update storage.buckets set public=false,file_size_limit=10485760,
 allowed_mime_types=array['application/pdf','image/png','image/jpeg'] where id='mentor-reading-files';
update storage.buckets set public=false,file_size_limit=52428800,
 allowed_mime_types=array['video/mp4'] where id='mentor-video-files';

alter table public.learning_resources drop constraint resource_link;
alter table public.learning_resources add constraint resource_link check (
 case when attachment_path is not null then
   ((kind='Reading' and attachment_path ~ ('^'||author_id::text||'/[0-9a-f]{32}\.(pdf|png|jpg|jpeg)$'))
    or (kind='Video' and attachment_path ~ ('^'||author_id::text||'/[0-9a-f]{32}\.mp4$')))
   and (external_url='' or (public.valid_resource_link(external_url) and (
     public.resource_analysis_storage_key(external_url)='mentor-reading-files/'||attachment_path
     or (kind='Video' and public.resource_analysis_storage_key(external_url)='mentor-video-files/'||attachment_path))))
 else
   (kind='Guide' and char_length(trim(body))>=20 and (external_url='' or public.valid_resource_link(external_url)))
   or (kind in ('Video','Reading') and public.valid_resource_link(external_url))
 end
);

-- Replace only the known old policies. Entitlements still come from the existing
-- authoritative can_read_mentor_resource function and learning_resources RLS.
drop policy if exists "Mentors upload their reading files" on storage.objects;
drop policy if exists "Read files attached to accessible learning resources" on storage.objects;
create policy "Mentors upload typed resource files" on storage.objects for insert to authenticated
with check (public.can_author_content() and (
    (bucket_id='mentor-reading-files' and name ~ ('^'||auth.uid()::text||'/[0-9a-f]{32}\.(pdf|png|jpg|jpeg)$'))
    or (bucket_id='mentor-video-files' and name ~ ('^'||auth.uid()::text||'/[0-9a-f]{32}\.mp4$'))));
create policy "Read entitled resource files" on storage.objects for select to authenticated
using (bucket_id in ('mentor-reading-files','mentor-video-files')
  and exists(select 1 from public.learning_resources r
    where r.attachment_path=storage.objects.name
      and ((r.kind='Reading' and storage.objects.bucket_id='mentor-reading-files')
        or (r.kind='Video' and storage.objects.bucket_id in ('mentor-reading-files','mentor-video-files')))
      and ((r.external_url='' and storage.objects.bucket_id='mentor-reading-files')
        or public.resource_analysis_storage_key(r.external_url)=storage.objects.bucket_id||'/'||storage.objects.name)
      and public.can_read_mentor_resource(r.author_id,r.status,r.moderation_hidden)));
-- Restrictive boundaries prevent unrelated permissive Storage policies from
-- granting authenticated/anonymous users broader access to these two buckets.
create policy "Mentor resource upload boundary" on storage.objects as restrictive for insert to authenticated
with check (bucket_id not in ('mentor-reading-files','mentor-video-files') or (public.can_author_content() and (
    (bucket_id='mentor-reading-files' and name ~ ('^'||auth.uid()::text||'/[0-9a-f]{32}\.(pdf|png|jpg|jpeg)$'))
    or (bucket_id='mentor-video-files' and name ~ ('^'||auth.uid()::text||'/[0-9a-f]{32}\.mp4$')))));
create policy "Mentor resource read boundary" on storage.objects as restrictive for select to authenticated
using (bucket_id not in ('mentor-reading-files','mentor-video-files') or (bucket_id in ('mentor-reading-files','mentor-video-files')
  and exists(select 1 from public.learning_resources r
    where r.attachment_path=storage.objects.name
      and ((r.kind='Reading' and storage.objects.bucket_id='mentor-reading-files')
        or (r.kind='Video' and storage.objects.bucket_id in ('mentor-reading-files','mentor-video-files')))
      and ((r.external_url='' and storage.objects.bucket_id='mentor-reading-files')
        or public.resource_analysis_storage_key(r.external_url)=storage.objects.bucket_id||'/'||storage.objects.name)
      and public.can_read_mentor_resource(r.author_id,r.status,r.moderation_hidden))));
-- Uploads use fresh random paths. File replacement remains insert-new + update
-- the owned resource; backend account cleanup still bypasses client RLS.
create policy "Mentor resource immutable objects" on storage.objects as restrictive for update to authenticated
using(bucket_id not in ('mentor-reading-files','mentor-video-files'))
with check(bucket_id not in ('mentor-reading-files','mentor-video-files'));
create policy "Mentor resource anonymous boundary" on storage.objects as restrictive for all to anon
using(bucket_id not in ('mentor-reading-files','mentor-video-files'))
with check(bucket_id not in ('mentor-reading-files','mentor-video-files'));
notify pgrst,'reload schema';
commit;
