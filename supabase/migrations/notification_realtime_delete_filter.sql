-- Filter DELETE changes by user_id while keeping the existing Realtime publication.
-- With RLS enabled, clients still receive only the deleted row's primary key.
alter table public.notifications replica identity full;
