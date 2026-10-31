-- Delivery is opt-in. Existing in-app preferences and alerts are unchanged.
alter table public.notification_preferences
  add column if not exists push_enabled boolean not null default false;

create table if not exists public.project_push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fcm_token text not null unique check (length(btrim(fcm_token)) between 1 and 4096),
  platform text not null check (platform in ('android', 'ios')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index if not exists project_push_devices_active_user_idx
  on public.project_push_devices(user_id) where is_active;

alter table public.project_push_devices enable row level security;
revoke all on public.project_push_devices from anon;
grant select, insert, update, delete on public.project_push_devices to authenticated;

drop policy if exists project_push_devices_select_own on public.project_push_devices;
create policy project_push_devices_select_own on public.project_push_devices
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists project_push_devices_insert_own on public.project_push_devices;
create policy project_push_devices_insert_own on public.project_push_devices
  for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists project_push_devices_update_own on public.project_push_devices;
create policy project_push_devices_update_own on public.project_push_devices
  for update to authenticated using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
drop policy if exists project_push_devices_delete_own on public.project_push_devices;
create policy project_push_devices_delete_own on public.project_push_devices
  for delete to authenticated using (user_id = (select auth.uid()));

-- Reuse the existing generic timestamp trigger body if available.
do $$
declare touch_function regprocedure;
begin
  touch_function := to_regprocedure('public.notification_preferences_timestamp()');
  if touch_function is null then
    execute $fn$
      create or replace function public.project_push_device_timestamp()
      returns trigger language plpgsql set search_path = public, pg_temp as $body$
      begin new.updated_at := now(); return new; end;
      $body$;
    $fn$;
    touch_function := 'public.project_push_device_timestamp()'::regprocedure;
  end if;
  drop trigger if exists project_push_device_timestamp on public.project_push_devices;
  execute format('create trigger project_push_device_timestamp before update on public.project_push_devices
    for each row execute function %s', touch_function);
end;
$$;

-- A device token is an installation credential, not a client-supplied user ID.
-- Definer access is needed only to transfer that token away from an old account.
create or replace function public.register_project_push_device(
  p_fcm_token text, p_platform text
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_fcm_token is null or length(btrim(p_fcm_token)) not between 1 and 4096
      or p_fcm_token ~ '[[:space:]]'
      or p_platform is null or p_platform not in ('android', 'ios') then
    raise exception 'Invalid push device registration' using errcode = '22023';
  end if;
  insert into public.project_push_devices (user_id, fcm_token, platform)
    values (current_user_id, p_fcm_token, p_platform)
  on conflict (fcm_token) do update set
    user_id = current_user_id,
    platform = excluded.platform,
    is_active = true,
    last_seen_at = now(),
    updated_at = now();
end;
$$;

create or replace function public.unregister_project_push_device(p_fcm_token text)
returns void language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_fcm_token is null or length(btrim(p_fcm_token)) not between 1 and 4096 then
    raise exception 'Invalid push device registration' using errcode = '22023';
  end if;
  update public.project_push_devices set is_active = false
    where user_id = auth.uid() and fcm_token = p_fcm_token;
end;
$$;

revoke all on function public.register_project_push_device(text, text) from public, anon;
revoke all on function public.unregister_project_push_device(text) from public, anon;
grant execute on function public.register_project_push_device(text, text) to authenticated;
grant execute on function public.unregister_project_push_device(text) to authenticated;
