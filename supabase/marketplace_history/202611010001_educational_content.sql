-- Run ONCE, after the profiles setup. Does not change existing profile data.
begin;

-- Only administrators using SQL Editor/service role may approve publishers.
create table public.content_publishers (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  approved_at timestamptz not null default now()
);
alter table public.content_publishers enable row level security;
revoke all on public.content_publishers from anon, authenticated;
grant select on public.content_publishers to authenticated;
create policy "Read own publishing approval" on public.content_publishers
  for select to authenticated using (user_id = (select auth.uid()));

create function public.can_author_content() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_verified_account() and exists (
    select 1 from public.profiles where id = (select auth.uid()) and role = 'mentor');
$$;
create function public.can_publish_content() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.can_author_content() and exists (
    select 1 from public.content_publishers where user_id = (select auth.uid()));
$$;
revoke all on function public.can_author_content() from public, anon;
revoke all on function public.can_publish_content() from public, anon;
grant execute on function public.can_author_content(), public.can_publish_content() to authenticated;

create function public.valid_resource_link(value text) returns boolean
language sql immutable set search_path = '' as $$
  select length(value) <= 2000 and value ~ '^https://[^/@[:space:]]+[.][^/@[:space:]]+([/?#][^[:space:]]*)?$';
$$;
create function public.valid_resource_tags(value text[]) returns boolean
language sql immutable set search_path = '' as $$
  select cardinality(value) <= 8 and not exists (
    select 1 from unnest(value) tag where tag is null or char_length(trim(tag)) not between 1 and 30);
$$;

create table public.learning_resources (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  author_name text not null default '',
  title text not null check (char_length(trim(title)) between 3 and 120),
  summary text not null check (char_length(trim(summary)) between 20 and 500),
  category text not null check (category in ('Programming', 'Design', 'Business', 'Languages', 'Music', 'Lifestyle', 'Other')),
  difficulty text not null check (difficulty in ('Beginner', 'Intermediate', 'Advanced')),
  kind text not null check (kind in ('Video', 'Guide', 'Reading')),
  external_url text not null default '',
  body text not null default '' check (char_length(body) <= 20000),
  tags text[] not null default '{}' check (public.valid_resource_tags(tags)),
  status text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  moderation_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint resource_link check (
    (kind = 'Guide' and char_length(trim(body)) >= 20 and
      (external_url = '' or public.valid_resource_link(external_url))) or
    (kind in ('Video', 'Reading') and public.valid_resource_link(external_url))
  )
);
create index resources_author on public.learning_resources(author_id, created_at desc);
create index resources_catalog on public.learning_resources(category, difficulty, kind, created_at desc)
  where status = 'published' and not moderation_hidden;
create index resources_tags on public.learning_resources using gin(tags);

-- Avoid making private profiles (including birth dates/emails) public for author names.
create function public.stamp_resource() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  select full_name into new.author_name from public.profiles where id = new.author_id;
  new.updated_at = now();
  return new;
end;
$$;
revoke all on function public.stamp_resource() from public, anon, authenticated;
create trigger resource_stamp before insert or update on public.learning_resources
  for each row execute function public.stamp_resource();

alter table public.learning_resources enable row level security;
revoke all on public.learning_resources from anon, authenticated;
grant select, delete on public.learning_resources to authenticated;
grant insert (author_id, title, summary, category, difficulty, kind, external_url, body, tags, status)
  on public.learning_resources to authenticated;
grant update (title, summary, category, difficulty, kind, external_url, body, tags, status)
  on public.learning_resources to authenticated;

-- A security-definer visibility helper is necessary: approvals themselves are private.
create function public.is_content_publisher(candidate uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.content_publishers cp
    join public.profiles p on p.id = cp.user_id
    where cp.user_id = candidate and p.role = 'mentor');
$$;
revoke all on function public.is_content_publisher(uuid) from public, anon;
grant execute on function public.is_content_publisher(uuid) to authenticated;
create policy "Read visible or own resources" on public.learning_resources
for select to authenticated using (
  (select public.is_verified_account()) and
  (author_id = (select auth.uid()) or
    (status = 'published' and not moderation_hidden and public.is_content_publisher(author_id)))
);
create policy "Mentors create own resources" on public.learning_resources
for insert to authenticated with check (
  author_id = (select auth.uid()) and (select public.can_author_content()) and
  (status <> 'published' or (select public.can_publish_content()))
);
create policy "Mentors edit own resources" on public.learning_resources
for update to authenticated using (
  author_id = (select auth.uid()) and (select public.can_author_content())
) with check (
  author_id = (select auth.uid()) and (select public.can_author_content()) and
  (status <> 'published' or (select public.can_publish_content()))
);
create policy "Authors delete own resources" on public.learning_resources
for delete to authenticated using (author_id = (select auth.uid()) and (select public.is_verified_account()));

create table public.content_bookmarks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  resource_id uuid not null references public.learning_resources(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, resource_id)
);
alter table public.content_bookmarks enable row level security;
revoke all on public.content_bookmarks from anon, authenticated;
grant select, delete on public.content_bookmarks to authenticated;
grant insert (user_id, resource_id) on public.content_bookmarks to authenticated;
-- Plain insert with ignoreDuplicates is used by the app; no UPDATE privilege needed.
create policy "Read own bookmarks" on public.content_bookmarks for select to authenticated
  using (user_id = (select auth.uid()) and exists (select 1 from public.learning_resources where id = resource_id));
create policy "Save visible resources" on public.content_bookmarks for insert to authenticated
  with check (user_id = (select auth.uid()) and (select public.is_verified_account()) and
    exists (select 1 from public.learning_resources where id = resource_id));
create policy "Remove own bookmarks" on public.content_bookmarks for delete to authenticated
  using (user_id = (select auth.uid()));

create table public.content_reports (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.learning_resources(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (reason in ('Inaccurate information', 'Inappropriate content', 'Copyright concern', 'Broken link', 'Spam', 'Other')),
  details text not null check (char_length(trim(details)) between 10 and 1000),
  status text not null default 'pending' check (status in ('pending', 'resolved', 'dismissed')),
  created_at timestamptz not null default now(),
  unique(resource_id, reporter_id)
);
alter table public.content_reports enable row level security;
revoke all on public.content_reports from anon, authenticated;
grant insert (resource_id, reporter_id, reason, details) on public.content_reports to authenticated;
create policy "Report other visible published resources" on public.content_reports for insert to authenticated
  with check (reporter_id = (select auth.uid()) and (select public.is_verified_account()) and exists (
    select 1 from public.learning_resources where id = resource_id and author_id <> (select auth.uid())
      and status = 'published' and not moderation_hidden));
-- Reports and reporter identities are reviewed only by the project administrator
-- through Supabase Table Editor. Clients cannot read reports or moderate content.
commit;
notify pgrst, 'reload schema';
