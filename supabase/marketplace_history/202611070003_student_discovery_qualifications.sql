-- Run once after 202611070002_tutor_management.sql.
begin;

create function public.is_student_account() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_verified_account() and exists(select 1 from public.profiles
    where id = auth.uid() and role = 'student');
$$;
revoke all on function public.is_student_account() from public,anon;
grant execute on function public.is_student_account() to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('mentor-qualifications','mentor-qualifications',false,10485760,
  array['application/pdf','image/jpeg','image/png']);

alter table public.tutor_profiles add column qualification_path text not null default '';

create function public.has_tutor_qualification(p_path text, p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_path <> '' and split_part(p_path,'/',1) = p_user::text
    and exists(select 1 from storage.objects where bucket_id = 'mentor-qualifications'
      and name = p_path and metadata->>'mimetype' in ('application/pdf','image/jpeg','image/png')
      and (metadata->>'size')::bigint between 1 and 10485760);
$$;
revoke all on function public.has_tutor_qualification(text,uuid) from public,anon,authenticated;

create policy "Upload own qualification evidence" on storage.objects for insert to authenticated
with check (bucket_id = 'mentor-qualifications' and public.can_author_content()
  and split_part(name,'/',1) = auth.uid()::text
  and array_length(string_to_array(name,'/'),1) = 2
  and split_part(name,'/',2) ~ '^[A-Za-z0-9_-]+[.](pdf|jpg|jpeg|png)$');
create policy "Read own qualification evidence" on storage.objects for select to authenticated
using (bucket_id = 'mentor-qualifications' and public.is_verified_account()
  and split_part(name,'/',1) = auth.uid()::text);
create policy "Remove unattached qualification evidence" on storage.objects for delete to authenticated
using (bucket_id = 'mentor-qualifications' and public.is_verified_account()
  and split_part(name,'/',1) = auth.uid()::text
  and not exists(select 1 from public.tutor_profiles where qualification_path = name));
-- No UPDATE policy: evidence cannot be overwritten after it has been reviewed.

-- Existing applications need a qualification document under the new requirement.
update public.tutor_profiles set verification_status = 'unsubmitted', reviewed_at = null,
  review_note = 'Please upload a qualification document and submit for verification.'
where verification_status in ('approved','pending');
-- Retire legacy manual publishing grants that have no verified qualification.
delete from public.content_publishers cp where not exists (
  select 1 from public.tutor_profiles t where t.user_id = cp.user_id
    and t.verification_status = 'approved' and t.qualification_path <> '');

create function public.require_tutor_qualification() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.verification_status in ('pending','approved') and
      (not public.has_tutor_qualification(new.qualification_path,new.user_id)
       or char_length(trim(new.experience)) < 20 or char_length(trim(new.expertise)) < 3
       or char_length(trim(new.headline)) < 3 or char_length(trim(new.teaching_preferences)) < 3) then
    raise exception 'Upload your qualification document and complete your mentor profile before verification.';
  end if;
  return new;
end;
$$;
revoke all on function public.require_tutor_qualification() from public,anon,authenticated;
create trigger require_qualification before insert or update on public.tutor_profiles
for each row execute function public.require_tutor_qualification();

drop function public.save_tutor_profile(text,text,text,text,text,boolean);
create function public.save_tutor_profile(p_headline text, p_expertise text,
  p_experience text, p_credential_url text, p_preferences text, p_submit boolean,
  p_qualification_path text) returns void
language plpgsql security definer set search_path = '' as $$
declare previous public.tutor_profiles; evidence_changed boolean;
begin
  if not public.can_author_content() then raise exception 'Choose Mentor in your profile first.'; end if;
  select * into previous from public.tutor_profiles where user_id = auth.uid() for update;
  if not found then raise exception 'Enable your mentor profile first.'; end if;
  if p_qualification_path <> '' and not public.has_tutor_qualification(p_qualification_path,auth.uid()) then
    raise exception 'Your qualification upload is missing or invalid. Upload a PDF, JPEG or PNG up to 10 MB.';
  end if;
  if p_submit and not public.has_tutor_qualification(p_qualification_path,auth.uid()) then
    raise exception 'Upload a qualification document before submitting for verification.';
  end if;
  evidence_changed := previous.experience <> trim(p_experience)
    or previous.expertise <> trim(p_expertise) or previous.credential_url <> trim(p_credential_url)
    or previous.qualification_path <> p_qualification_path;
  update public.tutor_profiles set headline = trim(p_headline), expertise = trim(p_expertise),
    experience = trim(p_experience), credential_url = trim(p_credential_url),
    teaching_preferences = trim(p_preferences), qualification_path = p_qualification_path,
    verification_status = case when p_submit then 'pending'
      when evidence_changed and verification_status in ('approved','pending') then 'unsubmitted'
      else verification_status end,
    submitted_at = case when p_submit then now() else submitted_at end,
    reviewed_at = case when p_submit or evidence_changed then null else reviewed_at end,
    review_note = case when p_submit or evidence_changed then '' else review_note end,
    updated_at = now() where user_id = auth.uid();
end;
$$;
revoke all on function public.save_tutor_profile(text,text,text,text,text,boolean,text) from public,anon;
grant execute on function public.save_tutor_profile(text,text,text,text,text,boolean,text) to authenticated;

create or replace function public.tutor_directory() returns table(user_id uuid, full_name text,
  headline text, expertise text, teaching_preferences text, average_rating numeric, review_count bigint)
language sql stable security definer set search_path = '' as $$
  select t.user_id,p.full_name,t.headline,t.expertise,t.teaching_preferences,
    (select round(avg(r.rating),1) from public.mentor_reviews r where r.mentor_id = t.user_id),
    (select count(*) from public.mentor_reviews r where r.mentor_id = t.user_id)
  from public.tutor_profiles t join public.profiles p on p.id = t.user_id
  where public.is_student_account() and public.is_approved_tutor(t.user_id)
  order by p.full_name,t.user_id;
$$;

create or replace function public.available_mentor_slots(p_mentor uuid)
returns table(id uuid, starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select s.id,s.starts_at,s.ends_at from public.mentor_slots s
  where s.mentor_id = p_mentor and s.starts_at > now()
    and public.is_student_account() and public.is_approved_tutor(p_mentor)
    and not exists(select 1 from public.mentorship_requests r where r.slot_id = s.id
      and (r.status in ('accepted','completed') or r.learner_id = auth.uid()))
  order by s.starts_at;
$$;

alter function public.request_mentorship(uuid,text) rename to request_mentorship_internal;
revoke all on function public.request_mentorship_internal(uuid,text) from public,anon,authenticated;
create function public.request_mentorship(p_slot uuid, p_message text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_student_account() then raise exception 'Only student accounts can request a mentor.'; end if;
  perform public.request_mentorship_internal(p_slot,p_message);
end;
$$;
revoke all on function public.request_mentorship(uuid,text) from public,anon;
grant execute on function public.request_mentorship(uuid,text) to authenticated;

drop policy "Read own or approved mentor slots" on public.mentor_slots;
create policy "Read own or student visible mentor slots" on public.mentor_slots for select to authenticated
using (public.is_verified_account() and (mentor_id = auth.uid() or
  (public.is_student_account() and public.is_approved_tutor(mentor_id))));

create or replace function public.tutor_feedback(p_mentor uuid)
returns table(rating integer, review text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select r.rating,r.review,r.created_at from public.mentor_reviews r
  where r.mentor_id = p_mentor and public.is_verified_account()
    and (p_mentor = auth.uid() or (public.is_student_account() and public.is_approved_tutor(p_mentor)))
  order by r.created_at desc;
$$;
commit;
notify pgrst, 'reload schema';
