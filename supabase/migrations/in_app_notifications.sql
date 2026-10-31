-- In-app records only. A trusted scheduler/monitor should invoke generation
-- when deadlines, stalled transitions, or recommendation batches occur.
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type varchar(50) not null check (type in
    ('STALLED_TASK', 'DEADLINE_REMINDER', 'LEARNING_RESOURCE_RECOMMENDATION')),
  context_type varchar(30) not null check (context_type in
    ('TASK', 'PROJECT', 'RECOMMENDATION')),
  project_id uuid references public.projects(id) on delete cascade,
  board_id uuid references public.kanban_boards(id) on delete cascade,
  task_id uuid references public.kanban_tasks(id) on delete cascade,
  title varchar(200) not null check (length(trim(title)) > 0),
  message text not null check (length(trim(message)) > 0),
  is_read boolean not null default false,
  read_at timestamptz,
  action_data jsonb not null default '{}'::jsonb,
  unique_key varchar(255),
  created_at timestamptz not null default now(),
  constraint notification_read_state check (is_read = (read_at is not null)),
  constraint notification_context_matches_type check (
    (type = 'STALLED_TASK' and context_type = 'TASK') or
    (type = 'DEADLINE_REMINDER' and context_type in ('TASK', 'PROJECT')) or
    (type = 'LEARNING_RESOURCE_RECOMMENDATION' and context_type = 'RECOMMENDATION')),
  constraint notification_target_required check (project_id is not null and
    (context_type = 'PROJECT' or (board_id is not null and task_id is not null)))
);

create index if not exists idx_notifications_user_created
  on public.notifications(user_id, created_at desc);
create index if not exists idx_notifications_user_unread
  on public.notifications(user_id, is_read, created_at desc);
create index if not exists idx_notifications_task on public.notifications(task_id);
create index if not exists idx_notifications_project on public.notifications(project_id);
create unique index if not exists uq_notifications_unique_key
  on public.notifications(user_id, unique_key) where unique_key is not null;

create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  stalled_task_enabled boolean not null default true,
  deadline_reminder_enabled boolean not null default true,
  recommendation_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.notification_read_only_update()
returns trigger language plpgsql as $$
begin
  if (to_jsonb(new) - 'is_read' - 'read_at') is distinct from
     (to_jsonb(old) - 'is_read' - 'read_at') then
    raise exception 'Only read state may be changed';
  end if;
  if old.is_read and not new.is_read then
    raise exception 'A read notification cannot be made unread';
  end if;
  return new;
end;
$$;

create trigger notification_read_only_update
before update on public.notifications for each row
execute function public.notification_read_only_update();

create or replace function public.notification_preferences_timestamp()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger notification_preferences_timestamp
before update on public.notification_preferences for each row
execute function public.notification_preferences_timestamp();

alter table public.notifications enable row level security;
alter table public.notification_preferences enable row level security;

create policy notifications_select_own on public.notifications
for select to authenticated using (user_id = auth.uid());
create policy notifications_insert_own on public.notifications
for insert to authenticated with check (
  user_id = auth.uid() and
  exists (select 1 from public.projects p
    where p.id = project_id and p.owner_id = auth.uid()) and
  (board_id is null or exists (select 1 from public.kanban_boards b
    where b.id = board_id and b.project_id = project_id)) and
  (task_id is null or exists (select 1 from public.kanban_tasks t
    where t.id = task_id and t.board_id = board_id))
);
create policy notifications_update_own on public.notifications
for update to authenticated using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy notification_preferences_select_own
on public.notification_preferences for select to authenticated
using (user_id = auth.uid());
create policy notification_preferences_insert_own
on public.notification_preferences for insert to authenticated
with check (user_id = auth.uid());
create policy notification_preferences_update_own
on public.notification_preferences for update to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());
