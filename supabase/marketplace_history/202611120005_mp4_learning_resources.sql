begin;

alter table public.learning_resources
  drop constraint resource_link,
  add constraint resource_link check (
    case when attachment_path is not null then
      external_url = '' and (
        (kind = 'Reading' and attachment_path ~
          ('^' || author_id::text || '/[0-9a-f]{32}\.(pdf|png|jpg|jpeg)$'))
        or (kind = 'Video' and attachment_path ~
          ('^' || author_id::text || '/[0-9a-f]{32}\.mp4$'))
      )
    else
      (kind = 'Guide' and char_length(trim(body)) >= 20 and
        (external_url = '' or public.valid_resource_link(external_url))) or
      (kind in ('Video', 'Reading') and public.valid_resource_link(external_url))
    end
  );

update storage.buckets
set file_size_limit = 52428800,
    allowed_mime_types = array['application/pdf', 'image/png', 'image/jpeg', 'video/mp4']
where id = 'mentor-reading-files';

alter policy "Mentors upload their reading files"
on storage.objects
with check (
  bucket_id = 'mentor-reading-files'
  and public.can_author_content()
  and name ~ ('^' || auth.uid()::text || '/[0-9a-f]{32}\.(pdf|png|jpg|jpeg|mp4)$')
);

commit;
notify pgrst, 'reload schema';
