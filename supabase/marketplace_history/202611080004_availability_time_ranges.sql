-- Each weekly time range is now one session; no duration selection.
begin;
alter table public.mentor_slots drop constraint if exists mentor_slots_check;
alter table public.mentor_slots drop constraint if exists mentor_slots_time_range;
alter table public.mentor_slots add constraint mentor_slots_time_range check(ends_at > starts_at and ends_at <= starts_at + interval '24 hours');
create or replace function public.generate_weekly_mentor_slots(p_mentor uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tutor_profiles; d date; w jsonb; s timestamptz; e timestamptz;
begin
  select * into t from public.tutor_profiles where user_id = p_mentor for update;
  if not found or not public.is_approved_tutor(p_mentor) then return; end if;
  for d in select generate_series((now() at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::date,
    (now() at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::date + 27,interval '1 day')::date loop
    for w in select value from jsonb_array_elements(t.weekly_availability) where (value->>'day')::integer = extract(isodow from d)::integer loop
      s := (d::timestamp + make_interval(mins=>(w->>'start')::integer - t.utc_offset_minutes)) at time zone 'UTC';
      e := (d::timestamp + make_interval(mins=>(w->>'end')::integer - t.utc_offset_minutes)) at time zone 'UTC';
      if s > now() and not exists(select 1 from public.mentor_slots where mentor_id=p_mentor and starts_at < e and ends_at > s) then
        insert into public.mentor_slots(mentor_id,starts_at,ends_at,schedule_generated) values(p_mentor,s,e,true);
      end if;
    end loop;
  end loop;
end;
$$;
revoke all on function public.generate_weekly_mentor_slots(uuid) from public,anon,authenticated;

create or replace function public.publish_mentor_schedule(p_headline text,p_expertise text,p_experience text,
 p_credential_url text,p_preferences text,p_availability jsonb,p_session_minutes integer,p_utc_offset integer) returns void
language plpgsql security definer set search_path = '' as $$
declare w jsonb; days integer[] := '{}'; wd integer; a integer; b integer;
begin
 if not public.can_author_content() then raise exception 'Only mentors can publish a teaching schedule.'; end if;
 if p_utc_offset is null or p_utc_offset not between -720 and 840 then
   raise exception 'Choose a valid time zone.'; end if;
 if p_availability is null or jsonb_typeof(p_availability) <> 'array' then raise exception 'Select your weekly availability.'; end if;
 if jsonb_array_length(p_availability) not between 1 and 7 then raise exception 'Select at least one free day.'; end if;
 for w in select value from jsonb_array_elements(p_availability) loop
   if jsonb_typeof(w->'day') is distinct from 'number' or jsonb_typeof(w->'start') is distinct from 'number' or jsonb_typeof(w->'end') is distinct from 'number'
     or (w->>'day') !~ '^[0-9]+$' or (w->>'start') !~ '^[0-9]+$' or (w->>'end') !~ '^[0-9]+$' then raise exception 'Invalid weekly availability.'; end if;
   wd := (w->>'day')::integer; a := (w->>'start')::integer; b := (w->>'end')::integer;
   if wd not between 1 and 7 or wd=any(days) or a not between 0 and 1439 or b not between 1 and 1440 or b <= a then
      raise exception 'Choose different days with an end time after the start and an end time after the start.'; end if;
   days := array_append(days,wd);
 end loop;
 perform 1 from public.tutor_profiles where user_id=auth.uid() for update;
 if not found then raise exception 'Create your mentor profile first.'; end if;
 update public.tutor_profiles set weekly_availability=p_availability,session_minutes=60,utc_offset_minutes=p_utc_offset where user_id=auth.uid();
 perform public.save_tutor_profile(p_headline,p_expertise,p_experience,p_credential_url,p_preferences,true,'');
 -- Keep every slot that already has a request, including cancelled/declined history.
 delete from public.mentor_slots s where s.mentor_id=auth.uid() and s.schedule_generated and s.starts_at>now()
   and not exists(select 1 from public.mentorship_requests r where r.slot_id=s.id);
 perform public.generate_weekly_mentor_slots(auth.uid());
end;
$$;
revoke all on function public.publish_mentor_schedule(text,text,text,text,text,jsonb,integer,integer) from public,anon;
grant execute on function public.publish_mentor_schedule(text,text,text,text,text,jsonb,integer,integer) to authenticated;

-- Replace only automatically generated, unrequested future sessions.
delete from public.mentor_slots s where s.schedule_generated and s.starts_at>now()
 and not exists(select 1 from public.mentorship_requests r where r.slot_id=s.id);
do $$ declare m uuid; begin
 for m in select user_id from public.tutor_profiles loop perform public.generate_weekly_mentor_slots(m); end loop;
end $$;
commit;
notify pgrst, 'reload schema';
