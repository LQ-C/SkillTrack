-- READ ONLY. Run on the chosen integration target; do not infer privacy from policy counts.
select expected.id, b.id is not null as bucket_exists, b.public,
       b.public=false as is_private, b.file_size_limit, b.allowed_mime_types
from (values('mentor-reading-files'),('mentor-video-files')) expected(id)
left join storage.buckets b on b.id=expected.id order by expected.id;
-- Show all Storage policies because an ALL/role-wide policy can affect these buckets.
select policyname,permissive,roles,cmd,qual,with_check
from pg_policies where schemaname='storage' and tablename='objects' order by policyname;
-- Check privileges explicitly; management read-only roles need not execute backend helpers.
select has_function_privilege('authenticated','public.resource_analysis_storage_key(text)','EXECUTE')
 as authenticated_storage_policy_helper,
 has_function_privilege('authenticated','public.can_read_mentor_resource(uuid,text,boolean)','EXECUTE')
 as authenticated_entitlement_helper;
-- Aggregate reference prefixes without calling backend-only functions.
select kind, count(*) filter(where attachment_path is not null and external_url='') as path_only_legacy,
 count(*) filter(where external_url like '%/storage/v1/object/authenticated/mentor-reading-files/%'
   or external_url like '%/storage/v1/object/public/mentor-reading-files/%') as reading_bucket,
 count(*) filter(where external_url like '%/storage/v1/object/authenticated/mentor-video-files/%'
   or external_url like '%/storage/v1/object/public/mentor-video-files/%') as video_bucket
from public.learning_resources group by kind order by kind;
