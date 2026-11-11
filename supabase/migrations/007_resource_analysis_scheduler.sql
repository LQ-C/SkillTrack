-- Configure Vault secrets before enabling the schedule. Missing secrets are a no-op.
begin;
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;
create or replace function public.invoke_resource_analysis_queue()
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare project_url text; shared_secret text;
begin
  select decrypted_secret into project_url from vault.decrypted_secrets where name='resource_analysis_url';
  select decrypted_secret into shared_secret from vault.decrypted_secrets where name='resource_analysis_cron_secret';
  if nullif(project_url,'') is null or length(coalesce(shared_secret,''))<32 then return; end if;
  perform net.http_post(
    url:=rtrim(project_url,'/')||'/functions/v1/resource-analysis-queue',
    headers:=jsonb_build_object('Content-Type','application/json','x-resource-analysis-secret',shared_secret),
    body:='{}'::jsonb,timeout_milliseconds:=75000);
end $$;
revoke all on function public.invoke_resource_analysis_queue() from public,anon,authenticated,service_role;
select cron.schedule('resource-analysis-queue-every-minute','* * * * *',
  $$select public.invoke_resource_analysis_queue();$$);
commit;
