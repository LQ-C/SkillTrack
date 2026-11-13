-- Follow-up to 018: authenticated Storage policies and the resource constraint
-- call this pure URL parser, previously restricted to backend-only callers.
-- It is immutable SECURITY INVOKER, reads no tables, and does not grant access
-- to files or bypass the existing resource/payment/moderation policies.
begin;
grant execute on function public.resource_analysis_storage_key(text) to authenticated;
notify pgrst,'reload schema';
commit;
