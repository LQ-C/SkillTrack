-- Private mentor libraries. A confirmed/completed booking AND mentor grant are required.
begin;
create table if not exists public.mentor_library_access (
  mentor_id uuid not null references public.profiles(id) on delete cascade,
  learner_id uuid not null references public.profiles(id) on delete cascade,
  granted_at timestamptz not null default now(),
  primary key(mentor_id,learner_id), check(mentor_id <> learner_id)
);
alter table public.mentor_library_access enable row level security;
revoke all on public.mentor_library_access from public,anon,authenticated;

create or replace function public.has_mentor_library_access(p_mentor uuid,p_learner uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.mentor_library_access a
   where a.mentor_id=p_mentor and a.learner_id=p_learner)
 and exists(select 1 from public.mentorship_requests r
   where r.mentor_id=p_mentor and r.learner_id=p_learner and r.status in ('accepted','completed'));
$$;
revoke all on function public.has_mentor_library_access(uuid,uuid) from public,anon,authenticated;

create or replace function public.my_learner_library_access(p_learner uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
 if not public.can_author_content() then raise exception 'Only mentors can manage learner access.'; end if;
 return public.has_mentor_library_access(auth.uid(),p_learner);
end;
$$;
create or replace function public.set_learner_library_access(p_learner uuid,p_grant boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if not public.can_author_content() then raise exception 'Only mentors can manage learner access.'; end if;
 if p_grant then
   if not exists(select 1 from public.mentorship_requests where mentor_id=auth.uid() and learner_id=p_learner and status in ('accepted','completed')) then
     raise exception 'Accept a booking from this student before granting library access.';
   end if;
   insert into public.mentor_library_access(mentor_id,learner_id) values(auth.uid(),p_learner)
     on conflict(mentor_id,learner_id) do update set granted_at=now();
 else
   delete from public.mentor_library_access where mentor_id=auth.uid() and learner_id=p_learner;
 end if;
end;
$$;
revoke all on function public.my_learner_library_access(uuid),public.set_learner_library_access(uuid,boolean) from public,anon;
grant execute on function public.my_learner_library_access(uuid),public.set_learner_library_access(uuid,boolean) to authenticated;

create or replace function public.can_read_mentor_resource(p_author uuid,p_status text,p_hidden boolean) returns boolean
language sql stable security definer set search_path = '' as $$
 select public.is_verified_account() and (
   (p_author=auth.uid() and public.can_author_content()) or
   (public.is_student_account() and p_status='published' and not p_hidden
     and public.is_content_publisher(p_author)
     and public.has_mentor_library_access(p_author,auth.uid())));
$$;
revoke all on function public.can_read_mentor_resource(uuid,text,boolean) from public,anon;
grant execute on function public.can_read_mentor_resource(uuid,text,boolean) to authenticated;
drop policy if exists "Read visible or own resources" on public.learning_resources;
create policy "Read visible or own resources" on public.learning_resources for select to authenticated
using(public.can_read_mentor_resource(author_id,status,moderation_hidden));
commit;
notify pgrst, 'reload schema';
