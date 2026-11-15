-- Metadata-only discovery for the mentor profile. Full rows and Storage retain existing RLS.
begin;
create or replace function public.mentor_resource_previews(p_mentor uuid, p_offset integer default 0)
returns table(id uuid,author_id uuid,author_name text,title text,summary text,category text,difficulty text,kind text,status text)
language plpgsql stable security definer set search_path='' as $$
begin
  if not public.is_verified_account() or not (public.is_student_account() or public.can_author_content()) then
    raise exception 'Verified account required' using errcode='42501';
  end if;
  if p_offset < 0 or p_offset > 100000 then raise exception 'Invalid offset'; end if;
  return query select r.id,r.author_id,r.author_name,r.title,left(r.summary,500),r.category,r.difficulty,r.kind,r.status
  from public.learning_resources r
  where r.author_id=p_mentor and r.status='published' and not r.moderation_hidden
    and public.is_content_publisher(r.author_id)
    and (r.author_id=auth.uid() or exists(select 1 from public.tutor_profiles t where t.user_id=r.author_id and t.is_listed))
  order by r.created_at desc,r.id limit 20 offset p_offset;
end $$;
revoke all on function public.mentor_resource_previews(uuid,integer) from public,anon;
grant execute on function public.mentor_resource_previews(uuid,integer) to authenticated;
notify pgrst,'reload schema';
commit;
