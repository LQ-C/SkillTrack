-- Run after 202611070003_student_discovery_qualifications.sql.
begin;

-- Only the registration Edge Function can stage a qualification before signup.
create table public.mentor_signup_uploads (
  token uuid primary key,
  email text not null,
  qualification_path text not null unique,
  user_id uuid unique references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.mentor_signup_uploads enable row level security;
revoke all on public.mentor_signup_uploads from public,anon,authenticated;
grant all on public.mentor_signup_uploads to service_role;

create or replace function public.has_tutor_qualification(p_path text, p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_path <> '' and
    (split_part(p_path,'/',1) = p_user::text or exists(
      select 1 from public.mentor_signup_uploads where user_id = p_user and qualification_path = p_path))
    and exists(select 1 from storage.objects where bucket_id = 'mentor-qualifications'
      and name = p_path and metadata->>'mimetype' in ('application/pdf','image/jpeg','image/png')
      and (metadata->>'size')::bigint between 1 and 10485760);
$$;

create function public.owns_signup_qualification(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_verified_account() and exists(select 1 from public.mentor_signup_uploads
    where user_id = auth.uid() and qualification_path = p_path);
$$;
revoke all on function public.owns_signup_qualification(text) from public,anon;
grant execute on function public.owns_signup_qualification(text) to authenticated;

drop policy "Read own qualification evidence" on storage.objects;
create policy "Read own qualification evidence" on storage.objects for select to authenticated
using (bucket_id = 'mentor-qualifications' and public.is_verified_account()
  and (split_part(name,'/',1) = auth.uid()::text or public.owns_signup_qualification(name)));
drop policy "Remove unattached qualification evidence" on storage.objects;
create policy "Remove unattached qualification evidence" on storage.objects for delete to authenticated
using (bucket_id = 'mentor-qualifications' and public.is_verified_account()
  and (split_part(name,'/',1) = auth.uid()::text or public.owns_signup_qualification(name))
  and not exists(select 1 from public.tutor_profiles where qualification_path = name));

create or replace function public.handle_new_account()
returns trigger language plpgsql security definer set search_path = '' as $$
declare upload public.mentor_signup_uploads;
begin
  if coalesce(new.raw_user_meta_data->>'role','student') = 'mentor' then
    select * into upload from public.mentor_signup_uploads
    where token = (new.raw_user_meta_data->>'mentor_upload_token')::uuid
      and lower(email) = lower(new.email) and user_id is null
      and created_at > now() - interval '15 minutes' for update;
    if not found then raise exception 'Mentor registration requires a qualification upload.'; end if;
  end if;
  insert into public.profiles(id,full_name,date_of_birth,role)
  values(new.id,trim(new.raw_user_meta_data->>'full_name'),
    (new.raw_user_meta_data->>'date_of_birth')::date,
    coalesce(new.raw_user_meta_data->>'role','student'));
  if new.raw_user_meta_data->>'role' = 'mentor' then
    update public.mentor_signup_uploads set user_id = new.id where token = upload.token;
    insert into public.tutor_profiles(user_id,headline,expertise,experience,teaching_preferences,
      qualification_path,verification_status,submitted_at)
    values(new.id,trim(new.raw_user_meta_data->>'mentor_headline'),
      trim(new.raw_user_meta_data->>'mentor_expertise'),trim(new.raw_user_meta_data->>'mentor_experience'),
      trim(new.raw_user_meta_data->>'mentor_preferences'),upload.qualification_path,'pending',now());
  end if;
  return new;
end;
$$;
commit;
notify pgrst, 'reload schema';
