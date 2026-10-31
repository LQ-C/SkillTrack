-- Scheduled notification generation. This migration never deletes notifications.
-- It validates the base schema before installing any query helpers.
do $$
declare required record;
begin
  for required in select * from (values
    ('public', 'profiles', 'id'),
    ('public', 'projects', 'id'), ('public', 'projects', 'owner_id'),
    ('public', 'projects', 'name'), ('public', 'projects', 'status'),
    ('public', 'projects', 'end_date'),
    ('public', 'kanban_boards', 'id'),
    ('public', 'kanban_boards', 'project_id'),
    ('public', 'kanban_boards', 'is_archived'),
    ('public', 'kanban_tasks', 'id'),
    ('public', 'kanban_tasks', 'board_id'),
    ('public', 'kanban_tasks', 'title'),
    ('public', 'kanban_tasks', 'status'),
    ('public', 'kanban_tasks', 'is_archived'),
    ('public', 'kanban_tasks', 'deadline'),
    ('public', 'kanban_tasks', 'updated_at'),
    ('public', 'kanban_tasks', 'created_at'),
    ('public', 'task_activity_logs', 'task_id'),
    ('public', 'task_activity_logs', 'created_at'),
    ('public', 'notifications', 'user_id'),
    ('public', 'notifications', 'type'),
    ('public', 'notifications', 'context_type'),
    ('public', 'notifications', 'project_id'),
    ('public', 'notifications', 'board_id'),
    ('public', 'notifications', 'task_id'),
    ('public', 'notifications', 'title'),
    ('public', 'notifications', 'message'),
    ('public', 'notifications', 'is_read'),
    ('public', 'notifications', 'read_at'),
    ('public', 'notifications', 'action_data'),
    ('public', 'notifications', 'unique_key'),
    ('public', 'notifications', 'created_at'),
    ('public', 'notification_preferences', 'user_id'),
    ('public', 'notification_preferences', 'stalled_task_enabled'),
    ('public', 'notification_preferences', 'deadline_reminder_enabled'),
    ('public', 'notification_preferences', 'recommendation_enabled')
  ) as columns(schema_name, table_name, column_name) loop
    if not exists (select 1 from information_schema.columns c
      where c.table_schema = required.schema_name
        and c.table_name = required.table_name
        and c.column_name = required.column_name) then
      raise exception 'Notification automation requires %.%',
        required.table_name, required.column_name;
    end if;
  end loop;
  if exists (select 1 from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = 'notifications'
      and c.column_name in ('type', 'context_type')
      and c.data_type not in ('text', 'character varying')) then
    raise exception 'Notification type columns must be text or varchar for safe case normalization';
  end if;
  if to_regclass('vault.decrypted_secrets') is null then
    raise exception 'Enable Supabase Vault before installing the notification cron job';
  end if;
end;
$$;

-- Flutter serializes uppercase values. Replace known legacy lowercase checks
-- before normalizing stored records; an unknown incompatible check aborts safely.
alter table public.notifications drop constraint if exists notifications_type_valid;
alter table public.notifications drop constraint if exists notifications_context_valid;
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications drop constraint if exists notifications_context_type_check;
alter table public.notifications drop constraint if exists notification_context_matches_type;
alter table public.notifications drop constraint if exists notifications_context_reference_check;

drop trigger if exists notification_read_only_update on public.notifications;

update public.notifications
set type = upper(type), context_type = upper(context_type)
where type <> upper(type) or context_type <> upper(context_type);

create trigger notification_read_only_update
  before update on public.notifications
  for each row execute function public.notification_read_only_update();

alter table public.notifications add constraint notifications_type_valid
  check (type in ('STALLED_TASK', 'DEADLINE_REMINDER',
    'LEARNING_RESOURCE_RECOMMENDATION'));
alter table public.notifications add constraint notifications_context_valid
  check (context_type in ('TASK', 'PROJECT', 'RECOMMENDATION'));
alter table public.notifications add constraint notification_context_matches_type
  check ((type = 'STALLED_TASK' and context_type = 'TASK') or
    (type = 'DEADLINE_REMINDER' and context_type in ('TASK', 'PROJECT')) or
    (type = 'LEARNING_RESOURCE_RECOMMENDATION' and context_type = 'RECOMMENDATION'));
alter table public.notifications add constraint notifications_context_reference_check
  check ((context_type = 'PROJECT' and project_id is not null) or
    (context_type in ('TASK', 'RECOMMENDATION') and project_id is not null
      and board_id is not null and task_id is not null));

-- The earlier repository migration referenced auth.users. Align existing
-- installations with profiles only when every persisted row has a profile.
-- A mismatch aborts this transaction without deleting or rewriting alerts.
do $$
declare old_fk record;
begin
  if exists (select 1 from public.notifications n
    left join public.profiles p on p.id = n.user_id
    where p.id is null) then
    raise exception 'Notification users without profiles must be reviewed before migration';
  end if;
  for old_fk in
    select c.conname, c.confrelid
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid
      and a.attname = 'user_id'
    where c.conrelid = 'public.notifications'::regclass
      and c.contype = 'f' and c.conkey = array[a.attnum]::smallint[]
  loop
    if old_fk.confrelid <> 'public.profiles'::regclass then
      execute format('alter table public.notifications drop constraint %I',
        old_fk.conname);
    end if;
  end loop;
  if not exists (select 1 from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attname = 'user_id'
    where c.conrelid = 'public.notifications'::regclass
      and c.contype = 'f' and c.conkey = array[a.attnum]::smallint[]
      and c.confrelid = 'public.profiles'::regclass) then
    alter table public.notifications add constraint notifications_user_profile_fkey
      foreign key (user_id) references public.profiles(id) on delete cascade;
  end if;
end;
$$;

-- Reuse the existing partial unique index instead of storing unread counts or
-- creating a duplicate index with the requested canonical name.
do $$
begin
  if to_regclass('public.notifications_user_unique_key_idx') is null then
    if to_regclass('public.uq_notifications_unique_key') is not null then
      alter index public.uq_notifications_unique_key
        rename to notifications_user_unique_key_idx;
    else
      create unique index notifications_user_unique_key_idx
        on public.notifications(user_id, unique_key)
        where unique_key is not null;
    end if;
  end if;
end;
$$;

create index if not exists notification_activity_latest_idx
  on public.task_activity_logs(task_id, created_at desc);

-- Generation is trusted. Existing clients keep SELECT and read-state UPDATE,
-- but cannot insert arbitrary notification rows.
drop policy if exists notifications_insert_own on public.notifications;
revoke insert on public.notifications from public, anon, authenticated;

create or replace function public.notification_project_candidates(
  p_offset integer, p_limit integer)
returns table (
  project_id uuid, user_id uuid, project_name text, end_date text,
  project_status text, profile_exists boolean)
language sql stable security invoker
set search_path = public, pg_temp set timezone = 'UTC' as $$
  select p.id, p.owner_id, p.name::text, p.end_date::text,
    p.status::text, pr.id is not null
  from public.projects p
  left join public.profiles pr on pr.id = p.owner_id
  where p.end_date is not null and p.status = 'active'
  order by p.id
  offset greatest(p_offset, 0)
  limit least(greatest(p_limit, 1), 500);
$$;

create or replace function public.notification_task_candidates(
  p_offset integer, p_limit integer)
returns table (
  task_id uuid, board_id uuid, project_id uuid, user_id uuid,
  task_title text, task_status text, task_archived boolean,
  board_archived boolean, project_status text, profile_exists boolean,
  deadline text, last_activity_at text)
language sql stable security invoker
set search_path = public, pg_temp set timezone = 'UTC' as $$
  select t.id, b.id, p.id, p.owner_id, t.title::text, t.status::text,
    coalesce(t.is_archived, false), coalesce(b.is_archived, false),
    p.status::text, pr.id is not null, t.deadline::text,
    coalesce(activity.created_at, t.updated_at, t.created_at)::text
  from public.kanban_tasks t
  join public.kanban_boards b on b.id = t.board_id
  join public.projects p on p.id = b.project_id
  left join public.profiles pr on pr.id = p.owner_id
  left join lateral (
    select l.created_at from public.task_activity_logs l
    where l.task_id = t.id
    order by l.created_at desc limit 1
  ) activity on true
  where p.status = 'active' and not coalesce(b.is_archived, false)
    and not coalesce(t.is_archived, false) and t.status <> 'completed'
  order by t.id
  offset greatest(p_offset, 0)
  limit least(greatest(p_limit, 1), 500);
$$;

-- The partial unique index is the final duplicate guard across concurrent runs.
create or replace function public.enqueue_app_notification(p_notification jsonb)
returns boolean language plpgsql security invoker
set search_path = public, pg_temp as $$
begin
  insert into public.notifications (
    user_id, type, context_type, project_id, board_id, task_id,
    title, message, action_data, unique_key)
  values (
    (p_notification->>'user_id')::uuid,
    p_notification->>'type', p_notification->>'context_type',
    (p_notification->>'project_id')::uuid,
    (p_notification->>'board_id')::uuid,
    (p_notification->>'task_id')::uuid,
    p_notification->>'title', p_notification->>'message',
    coalesce(p_notification->'action_data', '{}'::jsonb),
    p_notification->>'unique_key')
  on conflict (user_id, unique_key) where unique_key is not null do nothing;
  return found;
end;
$$;

revoke all on function public.notification_project_candidates(integer, integer)
  from public, anon, authenticated;
revoke all on function public.notification_task_candidates(integer, integer)
  from public, anon, authenticated;
revoke all on function public.enqueue_app_notification(jsonb)
  from public, anon, authenticated;
grant execute on function public.notification_project_candidates(integer, integer)
  to service_role;
grant execute on function public.notification_task_candidates(integer, integer)
  to service_role;
grant execute on function public.enqueue_app_notification(jsonb)
  to service_role;

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

-- Set the two Vault secrets before expecting successful invocations. The job
-- is safe to install first: it does nothing while either secret is missing.
create or replace function public.invoke_project_notification_generator()
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare project_url text;
declare cron_secret text;
begin
  select decrypted_secret into project_url
  from vault.decrypted_secrets where name = 'project_notification_url';
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets where name = 'project_notification_cron_secret';
  if nullif(project_url, '') is null or nullif(cron_secret, '') is null then
    raise warning 'Notification cron secrets are not configured';
    return;
  end if;
  perform net.http_post(
    url := rtrim(project_url, '/') || '/functions/v1/project-notification-generator',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-notification-cron-secret', cron_secret),
    body := '{}'::jsonb
  );
end;
$$;

revoke all on function public.invoke_project_notification_generator()
  from public, anon, authenticated, service_role;

select cron.schedule('project-notification-generator-hourly', '0 * * * *',
  $$select public.invoke_project_notification_generator();$$);
