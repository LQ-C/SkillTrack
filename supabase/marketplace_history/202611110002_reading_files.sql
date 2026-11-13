alter table public.learning_resources add column attachment_path text;

create index learning_resources_attachment_path
  on public.learning_resources (attachment_path)
  where attachment_path is not null;

alter table public.learning_resources
  drop constraint resource_link,
  add constraint resource_link check (
    case when attachment_path is not null then
      kind = 'Reading' and external_url = ''
      and attachment_path ~ ('^' || author_id::text || '/[0-9a-f]{32}\.(pdf|png|jpg|jpeg)$')
    else
      (kind = 'Guide' and char_length(trim(body)) >= 20 and
        (external_url = '' or public.valid_resource_link(external_url))) or
      (kind in ('Video', 'Reading') and public.valid_resource_link(external_url))
    end
  );

grant insert (attachment_path), update (attachment_path)
  on public.learning_resources to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'mentor-reading-files', 'mentor-reading-files', false, 10485760,
  array['application/pdf', 'image/png', 'image/jpeg']
);

create policy "Mentors upload their reading files"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'mentor-reading-files'
  and public.can_author_content()
  and name ~ ('^' || auth.uid()::text || '/[0-9a-f]{32}\.(pdf|png|jpg|jpeg)$')
);

-- The learning_resources SELECT policy also applies inside this lookup.
create policy "Read files attached to accessible learning resources"
on storage.objects for select to authenticated
using (
  bucket_id = 'mentor-reading-files'
  and exists (
    select 1 from public.learning_resources r
    where r.attachment_path = storage.objects.name
      and public.can_read_mentor_resource(r.author_id, r.status, r.moderation_hidden)
  )
);
