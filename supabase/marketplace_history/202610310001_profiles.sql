-- Run once in a new Supabase project's SQL Editor before registering users.
begin;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (char_length(trim(full_name)) between 2 and 100
    and full_name !~ '[0-9<>[:cntrl:]]'),
  date_of_birth date not null check (date_of_birth between date '1900-01-01' and current_date),
  role text not null default 'student' check (role in ('student', 'mentor')),
  bio text not null default '' check (char_length(bio) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column public.profiles.role is 'User preference only; never use this as proof of tutor verification or administrative permissions.';
alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, date_of_birth, role, bio) on public.profiles to authenticated;

-- Email confirmation is checked against the authoritative auth record instead
-- of relying on optional JWT claims (Supabase tokens need not include that claim).
create or replace function public.is_verified_account()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from auth.users
    where id = (select auth.uid()) and email_confirmed_at is not null);
$$;
revoke all on function public.is_verified_account() from public, anon;
grant execute on function public.is_verified_account() to authenticated;

create policy "Read own profile" on public.profiles
  for select to authenticated using (id = (select auth.uid()) and (select public.is_verified_account()));
create policy "Update own profile" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()) and (select public.is_verified_account()))
  with check (id = (select auth.uid()) and (select public.is_verified_account()));

create or replace function public.handle_new_account()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name, date_of_birth, role)
  values (new.id, trim(new.raw_user_meta_data ->> 'full_name'),
    (new.raw_user_meta_data ->> 'date_of_birth')::date,
    coalesce(new.raw_user_meta_data ->> 'role', 'student'));
  return new;
end;
$$;
revoke all on function public.handle_new_account() from public, anon, authenticated;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_account();

create or replace function public.touch_profile()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
revoke all on function public.touch_profile() from public, anon, authenticated;
create trigger on_profile_updated before update on public.profiles
  for each row execute function public.touch_profile();
commit;
