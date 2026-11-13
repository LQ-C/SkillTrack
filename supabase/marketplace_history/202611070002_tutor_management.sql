-- Run after profiles and educational_content migrations. Never rerun the old setups.
begin;

create table public.tutor_profiles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  headline text not null default '' check (char_length(headline) <= 120),
  expertise text not null default '' check (char_length(expertise) <= 500),
  experience text not null default '' check (char_length(experience) <= 5000),
  credential_url text not null default '' check (credential_url = '' or public.valid_resource_link(credential_url)),
  teaching_preferences text not null default '' check (char_length(teaching_preferences) <= 1000),
  verification_status text not null default 'unsubmitted'
    check (verification_status in ('unsubmitted', 'pending', 'approved', 'rejected')),
  review_note text not null default '' check (char_length(review_note) <= 1000),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.tutor_profiles enable row level security;
revoke all on public.tutor_profiles from anon, authenticated;
grant select on public.tutor_profiles to authenticated;
create policy "Read own private tutor application" on public.tutor_profiles
for select to authenticated using (user_id = (select auth.uid()) and public.is_verified_account());

create function public.is_approved_tutor(candidate uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tutor_profiles t join public.profiles p on p.id = t.user_id
    join auth.users u on u.id = p.id
    where t.user_id = candidate and t.verification_status = 'approved'
      and p.role = 'mentor' and u.email_confirmed_at is not null);
$$;

-- All mutations go through functions; clients cannot approve themselves.
create function public.enable_tutor_profile() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_verified_account() then raise exception 'Verify your email first.'; end if;
  update public.profiles set role = 'mentor' where id = auth.uid();
  insert into public.tutor_profiles(user_id) values (auth.uid()) on conflict do nothing;
end;
$$;

create function public.save_tutor_profile(p_headline text, p_expertise text,
  p_experience text, p_credential_url text, p_preferences text, p_submit boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare previous public.tutor_profiles;
begin
  if not public.can_author_content() then raise exception 'Choose Mentor in your profile first.'; end if;
  select * into previous from public.tutor_profiles where user_id = auth.uid() for update;
  if not found then raise exception 'Enable your mentor profile first.'; end if;
  if (p_submit or previous.verification_status = 'approved') and (char_length(trim(p_headline)) < 3 or char_length(trim(p_expertise)) < 3
    or char_length(trim(p_experience)) < 20 or char_length(trim(p_preferences)) < 3) then
    raise exception 'Add your headline, expertise, experience and teaching preferences before submitting.';
  end if;
  update public.tutor_profiles set headline = trim(p_headline), expertise = trim(p_expertise),
    experience = trim(p_experience), credential_url = trim(p_credential_url),
    teaching_preferences = trim(p_preferences), updated_at = now(),
    -- Changing evidence on a pending/approved application requires review again.
    verification_status = case when p_submit then 'pending'
      when (experience <> trim(p_experience) or credential_url <> trim(p_credential_url)
        or expertise <> trim(p_expertise)) and verification_status in ('approved', 'pending')
      then 'unsubmitted' else verification_status end,
    review_note = case when p_submit then '' else review_note end,
    submitted_at = case when p_submit then now() else submitted_at end,
    reviewed_at = case when p_submit or experience <> trim(p_experience)
      or credential_url <> trim(p_credential_url) or expertise <> trim(p_expertise)
      then null else reviewed_at end
  where user_id = auth.uid();
end;
$$;

-- Approval also controls the existing library publishing permission.
create function public.sync_tutor_publisher() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.verification_status = 'approved' then
    insert into public.content_publishers(user_id) values(new.user_id) on conflict do nothing;
  else
    delete from public.content_publishers where user_id = new.user_id;
  end if;
  return new;
end;
$$;
create trigger tutor_publisher_sync after insert or update of verification_status
on public.tutor_profiles for each row execute function public.sync_tutor_publisher();

create table public.mentor_slots (
  id uuid primary key default gen_random_uuid(),
  mentor_id uuid not null references public.tutor_profiles(user_id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  check (ends_at > starts_at and ends_at <= starts_at + interval '8 hours')
);
create index mentor_slot_schedule on public.mentor_slots(mentor_id, starts_at);
alter table public.mentor_slots enable row level security;
revoke all on public.mentor_slots from anon, authenticated;
grant select on public.mentor_slots to authenticated;
create policy "Read own or approved mentor slots" on public.mentor_slots for select to authenticated
using (public.is_verified_account() and (mentor_id = auth.uid() or public.is_approved_tutor(mentor_id)));

create table public.mentorship_requests (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references public.mentor_slots(id) on delete cascade,
  mentor_id uuid not null references public.tutor_profiles(user_id) on delete cascade,
  learner_id uuid not null references public.profiles(id) on delete cascade,
  message text not null check (char_length(trim(message)) between 10 and 1000),
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled','completed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(slot_id, learner_id), check (mentor_id <> learner_id)
);
create unique index one_booking_per_slot on public.mentorship_requests(slot_id)
  where status in ('accepted','completed');
alter table public.mentorship_requests enable row level security;
revoke all on public.mentorship_requests from anon, authenticated;
grant select on public.mentorship_requests to authenticated;
create policy "Read participant requests" on public.mentorship_requests for select to authenticated
using (public.is_verified_account() and auth.uid() in (mentor_id,learner_id));

create table public.mentor_reviews (
  request_id uuid primary key references public.mentorship_requests(id) on delete cascade,
  mentor_id uuid not null references public.tutor_profiles(user_id) on delete cascade,
  learner_id uuid not null references public.profiles(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  review text not null check (char_length(trim(review)) between 10 and 1000),
  created_at timestamptz not null default now()
);
alter table public.mentor_reviews enable row level security;
revoke all on public.mentor_reviews from anon, authenticated;
-- Public review data is exposed only through the directory function below.

create function public.save_mentor_slot(p_id uuid, p_start timestamptz, p_end timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_verified_account() or not public.is_approved_tutor(auth.uid()) then
    raise exception 'Mentor approval is required to offer sessions.'; end if;
  -- Serialize edits and inserts for a mentor so overlapping times cannot race.
  perform 1 from public.tutor_profiles where user_id = auth.uid() for update;
  if p_start <= now() or p_end <= p_start or p_end > p_start + interval '8 hours' then
    raise exception 'Choose a future session lasting up to 8 hours.'; end if;
  if p_id is not null then
    perform 1 from public.mentor_slots where id = p_id and mentor_id = auth.uid() for update;
    if not found then raise exception 'Slot not found.'; end if;
    if exists(select 1 from public.mentorship_requests where slot_id = p_id) then
      raise exception 'This slot has requests. Keep it for the session history and create a new slot.'; end if;
  end if;
  if exists(select 1 from public.mentor_slots where mentor_id = auth.uid()
      and (p_id is null or id <> p_id) and starts_at < p_end and ends_at > p_start) then
    raise exception 'This time overlaps another availability slot.'; end if;
  if p_id is null then
    insert into public.mentor_slots(mentor_id,starts_at,ends_at) values(auth.uid(),p_start,p_end);
  else update public.mentor_slots set starts_at = p_start, ends_at = p_end where id = p_id; end if;
end;
$$;

create function public.delete_mentor_slot(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_verified_account() then raise exception 'Sign in first.'; end if;
  perform 1 from public.mentor_slots where id = p_id and mentor_id = auth.uid() for update;
  if not found then raise exception 'Slot not found.'; end if;
  if exists(select 1 from public.mentorship_requests where slot_id = p_id) then
    raise exception 'Slots with requests must be retained for session history.'; end if;
  delete from public.mentor_slots where id = p_id;
end;
$$;

create function public.request_mentorship(p_slot uuid, p_message text) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.mentor_slots;
begin
  if not public.is_verified_account() then raise exception 'Verify your email first.'; end if;
  select * into s from public.mentor_slots where id = p_slot for update;
  if not found or s.starts_at <= now() or not public.is_approved_tutor(s.mentor_id)
      or s.mentor_id = auth.uid() then raise exception 'This session is unavailable.'; end if;
  if exists(select 1 from public.mentorship_requests where slot_id = p_slot
    and status in ('accepted','completed')) then raise exception 'This session is already booked.'; end if;
  insert into public.mentorship_requests(slot_id,mentor_id,learner_id,message)
    values(p_slot,s.mentor_id,auth.uid(),trim(p_message));
end;
$$;

create function public.respond_mentorship(p_request uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.mentorship_requests; s public.mentor_slots;
begin
  if not public.is_verified_account() then raise exception 'Sign in first.'; end if;
  -- Always lock slot before request, matching request_mentorship's lock order.
  select sl.* into s from public.mentor_slots sl join public.mentorship_requests mr
    on mr.slot_id = sl.id where mr.id = p_request for update of sl;
  select * into r from public.mentorship_requests where id = p_request for update;
  if not found or auth.uid() not in (r.mentor_id,r.learner_id) then raise exception 'Request not found.'; end if;
  if p_status in ('accepted','declined') and auth.uid() = r.mentor_id and r.status = 'pending' then
    if p_status = 'accepted' and (s.starts_at <= now() or not public.is_approved_tutor(r.mentor_id)) then
      raise exception 'Only approved mentors can accept future sessions.'; end if;
  elsif p_status = 'cancelled' and r.status in ('pending','accepted') and s.starts_at > now() then
    null;
  elsif p_status = 'completed' and auth.uid() = r.mentor_id and r.status = 'accepted' and s.ends_at <= now() then
    null;
  else raise exception 'This request cannot move to that status.';
  end if;
  update public.mentorship_requests set status = p_status, updated_at = now() where id = p_request;
  if p_status = 'accepted' then
    update public.mentorship_requests set status = 'declined', updated_at = now()
      where slot_id = r.slot_id and id <> r.id and status = 'pending';
  end if;
end;
$$;

create function public.review_mentor(p_request uuid, p_rating integer, p_review text) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.mentorship_requests;
begin
  if not public.is_verified_account() then raise exception 'Sign in first.'; end if;
  select * into r from public.mentorship_requests where id = p_request for update;
  if not found or r.learner_id <> auth.uid() or r.status <> 'completed' then
    raise exception 'Only the learner from a completed session can leave feedback.'; end if;
  insert into public.mentor_reviews(request_id,mentor_id,learner_id,rating,review)
    values(r.id,r.mentor_id,auth.uid(),p_rating,trim(p_review));
end;
$$;

create function public.tutor_directory() returns table(user_id uuid, full_name text,
  headline text, expertise text, teaching_preferences text, average_rating numeric, review_count bigint)
language sql stable security definer set search_path = '' as $$
  select t.user_id,p.full_name,t.headline,t.expertise,t.teaching_preferences,
    (select round(avg(r.rating),1) from public.mentor_reviews r where r.mentor_id = t.user_id),
    (select count(*) from public.mentor_reviews r where r.mentor_id = t.user_id)
  from public.tutor_profiles t join public.profiles p on p.id = t.user_id
  where public.is_verified_account() and public.is_approved_tutor(t.user_id)
  order by p.full_name,t.user_id;
$$;

create function public.my_mentorship_sessions() returns table(id uuid, mentor_id uuid,
  learner_id uuid, mentor_name text, learner_name text, message text, status text,
  starts_at timestamptz, ends_at timestamptz, reviewed boolean)
language sql stable security definer set search_path = '' as $$
  select r.id,r.mentor_id,r.learner_id,mp.full_name,lp.full_name,r.message,r.status,
    s.starts_at,s.ends_at,exists(select 1 from public.mentor_reviews v where v.request_id = r.id)
  from public.mentorship_requests r join public.mentor_slots s on s.id = r.slot_id
    join public.profiles mp on mp.id = r.mentor_id join public.profiles lp on lp.id = r.learner_id
  where public.is_verified_account() and auth.uid() in (r.mentor_id,r.learner_id)
  order by s.starts_at desc;
$$;

create function public.tutor_feedback(p_mentor uuid) returns table(rating integer, review text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select r.rating,r.review,r.created_at from public.mentor_reviews r
  where r.mentor_id = p_mentor and public.is_verified_account()
    and (p_mentor = auth.uid() or public.is_approved_tutor(p_mentor)) order by r.created_at desc;
$$;

-- PostgreSQL grants EXECUTE to PUBLIC by default: explicitly restrict every RPC.
create function public.available_mentor_slots(p_mentor uuid)
returns table(id uuid, starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select s.id,s.starts_at,s.ends_at from public.mentor_slots s
  where s.mentor_id = p_mentor and s.starts_at > now()
    and public.is_verified_account() and public.is_approved_tutor(p_mentor)
    and not exists(select 1 from public.mentorship_requests r where r.slot_id = s.id
      and (r.status in ('accepted','completed') or r.learner_id = auth.uid()))
  order by s.starts_at;
$$;
revoke all on function public.available_mentor_slots(uuid) from public,anon;
grant execute on function public.available_mentor_slots(uuid) to authenticated;

revoke all on function public.is_approved_tutor(uuid), public.enable_tutor_profile(),
  public.save_tutor_profile(text,text,text,text,text,boolean), public.sync_tutor_publisher(),
  public.save_mentor_slot(uuid,timestamptz,timestamptz), public.delete_mentor_slot(uuid),
  public.request_mentorship(uuid,text), public.respond_mentorship(uuid,text),
  public.review_mentor(uuid,integer,text), public.tutor_directory(),
  public.my_mentorship_sessions(), public.tutor_feedback(uuid) from public,anon,authenticated;
grant execute on function public.is_approved_tutor(uuid), public.enable_tutor_profile(),
  public.save_tutor_profile(text,text,text,text,text,boolean),
  public.save_mentor_slot(uuid,timestamptz,timestamptz), public.delete_mentor_slot(uuid),
  public.request_mentorship(uuid,text), public.respond_mentorship(uuid,text),
  public.review_mentor(uuid,integer,text), public.tutor_directory(),
  public.my_mentorship_sessions(), public.tutor_feedback(uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
