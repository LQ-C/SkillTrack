-- Temporary open mentor access. Requires tutor migrations 002 and 003.
-- Email confirmation, ownership rules and student-only booking remain enforced.
begin;

create or replace function public.require_tutor_qualification() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.verification_status := 'approved';
  new.review_note := '';
  new.reviewed_at := null;
  return new;
end;
$$;

create or replace function public.handle_new_account() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id,full_name,date_of_birth,role)
  values(new.id,trim(new.raw_user_meta_data->>'full_name'),
    (new.raw_user_meta_data->>'date_of_birth')::date,
    coalesce(new.raw_user_meta_data->>'role','student'));
  return new;
end;
$$;

create or replace function public.is_approved_tutor(candidate uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.tutor_profiles t
    join public.profiles p on p.id = t.user_id
    join auth.users u on u.id = p.id
    where p.id = candidate and p.role = 'mentor' and u.email_confirmed_at is not null);
$$;

create or replace function public.sync_tutor_publisher() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists(select 1 from public.profiles where id = new.user_id and role = 'mentor') then
    insert into public.content_publishers(user_id) values(new.user_id) on conflict do nothing;
  else
    delete from public.content_publishers where user_id = new.user_id;
  end if;
  return new;
end;
$$;

create or replace function public.sync_open_mentor_role() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.role = 'mentor' then
    insert into public.tutor_profiles(user_id,verification_status)
    values(new.id,'approved') on conflict(user_id) do update
      set verification_status = 'approved', review_note = '', reviewed_at = null;
  else
    delete from public.content_publishers where user_id = new.id;
  end if;
  return new;
end;
$$;
revoke all on function public.sync_open_mentor_role() from public,anon,authenticated;
drop trigger if exists on_open_mentor_role on public.profiles;
create trigger on_open_mentor_role after insert or update of role on public.profiles
for each row execute function public.sync_open_mentor_role();

create or replace function public.enable_tutor_profile() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_verified_account() then raise exception 'Verify your email first.'; end if;
  update public.profiles set role = 'mentor' where id = auth.uid();
end;
$$;

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
    updated_at = now() where user_id = auth.uid();
  if not found then raise exception 'Create your mentor profile first.'; end if;
end;
$$;

-- Activate existing mentors too; keep all profiles, documents and bookings.
insert into public.tutor_profiles(user_id,verification_status)
select id,'approved' from public.profiles where role = 'mentor'
on conflict(user_id) do update set verification_status = 'approved', review_note = '', reviewed_at = null;
delete from public.content_publishers cp using public.profiles p
where cp.user_id = p.id and p.role <> 'mentor';
comment on column public.profiles.role is 'Temporary open role selection: mentors can teach without credential review. Email confirmation is still required.';
commit;
notify pgrst, 'reload schema';
