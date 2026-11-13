-- After canonical schema, apply 017 then 018 for complete split-bucket policies.
-- Review and run only on the chosen integration project after the canonical schema.
-- No policies are broadened. Existing buckets are not silently reconfigured.
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('mentor-reading-files','mentor-reading-files',false,10485760,array['application/pdf','image/png','image/jpeg']),
 ('mentor-video-files','mentor-video-files',false,52428800,array['video/mp4']),
 ('mentor-qualifications','mentor-qualifications',false,10485760,array['application/pdf','image/png','image/jpeg']),
 ('task-attachments','task-attachments',false,10485760,null)
on conflict(id) do nothing;
do $$ begin
 if exists(select 1 from storage.buckets where id in ('mentor-reading-files','mentor-video-files','mentor-qualifications','task-attachments') and public) then
   raise exception 'Required application buckets must remain private; review existing bucket settings';
 end if;
end $$;
commit;
