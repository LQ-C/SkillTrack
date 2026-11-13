-- Run after 202611070005_simplify_mentor_registration.sql.
-- Teaching preferences are no longer required for mentor registration.
begin;

create or replace function public.require_tutor_qualification() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.verification_status in ('pending','approved') and
      (not public.has_tutor_qualification(new.qualification_path,new.user_id)
       or char_length(trim(new.expertise)) < 3 or char_length(trim(new.headline)) < 3) then
    raise exception 'Upload your qualification document and complete your mentor profile before verification.';
  end if;
  return new;
end;
$$;

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
    values(new.id,left(trim(new.raw_user_meta_data->>'mentor_expertise'),120),
      trim(new.raw_user_meta_data->>'mentor_expertise'),
      coalesce(trim(new.raw_user_meta_data->>'mentor_experience'),''),
      coalesce(trim(new.raw_user_meta_data->>'mentor_preferences'),''),upload.qualification_path,'pending',now());
  end if;
  return new;
end;
$$;
commit;
notify pgrst, 'reload schema';

