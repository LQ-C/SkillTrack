-- Run after 202611080001_open_mentor_roles.sql. Mentor publication is opt-in.
begin;
alter table public.tutor_profiles add column if not exists is_listed boolean not null default false;

create or replace function public.save_tutor_profile(p_headline text, p_expertise text,
  p_experience text, p_credential_url text, p_preferences text, p_submit boolean,
  p_qualification_path text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can_author_content() then raise exception 'Choose Mentor in your profile first.'; end if;
  if char_length(trim(p_headline)) < 3 or char_length(trim(p_expertise)) < 3 then
    raise exception 'Add a headline and the skills you teach.';
  end if;
  -- Preserve old private evidence without requiring or changing it.
  update public.tutor_profiles set headline = trim(p_headline), expertise = trim(p_expertise),
    experience = trim(p_experience), credential_url = trim(p_credential_url),
    teaching_preferences = trim(p_preferences), verification_status = 'approved',
    is_listed = case when p_submit then true else is_listed end,
    updated_at = now() where user_id = auth.uid();
  if not found then raise exception 'Create your mentor profile first.'; end if;
end;
$$;

create or replace function public.tutor_directory() returns table(user_id uuid, full_name text,
  headline text, expertise text, teaching_preferences text, average_rating numeric, review_count bigint)
language sql stable security definer set search_path = '' as $$
  select t.user_id,p.full_name,t.headline,t.expertise,t.teaching_preferences,
    (select round(avg(r.rating),1) from public.mentor_reviews r where r.mentor_id = t.user_id),
    (select count(*) from public.mentor_reviews r where r.mentor_id = t.user_id)
  from public.tutor_profiles t join public.profiles p on p.id = t.user_id
  where public.is_student_account() and public.is_approved_tutor(t.user_id) and t.is_listed
  order by p.full_name,t.user_id;
$$;
commit;
notify pgrst, 'reload schema';
