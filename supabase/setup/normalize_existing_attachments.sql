-- Optional reviewed backfill after 017/018; never points at either source project.
-- Replace the placeholder with the chosen integration project's HTTPS URL.
-- Path-only records predate the split: KEEP their original reading bucket, including MP4.
-- Never rewrite them to the video bucket based on extension without an explicit file migration.
begin;
do $$
declare project_url text := 'https://REPLACE_ME.supabase.co';
begin
 if project_url like '%REPLACE_ME%' or project_url !~ '^https://[a-z0-9-]+\.supabase\.co$' then
   raise exception 'Set the integration project URL before running this backfill';
 end if;
 update public.learning_resources
 set external_url=project_url||'/storage/v1/object/authenticated/mentor-reading-files/'||attachment_path
 where attachment_path is not null and external_url='';
end $$;
commit;
