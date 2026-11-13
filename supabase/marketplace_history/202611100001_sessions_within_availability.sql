-- Availability windows contain individual sessions of up to one hour.
begin;
create or replace function public.generate_weekly_mentor_slots(p_mentor uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tutor_profiles; d date; w jsonb; s timestamptz; e timestamptz; window_end timestamptz;
begin
  select * into t from public.tutor_profiles where user_id = p_mentor for update;
  if not found or not public.is_approved_tutor(p_mentor) then return; end if;
  for d in select generate_series((now() at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::date,
    (now() at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::date + 27,interval '1 day')::date loop
    for w in select value from jsonb_array_elements(t.weekly_availability) where (value->>'day')::integer = extract(isodow from d)::integer loop
      s := (d::timestamp + make_interval(mins=>(w->>'start')::integer - t.utc_offset_minutes)) at time zone 'UTC';
      window_end := (d::timestamp + make_interval(mins=>(w->>'end')::integer - t.utc_offset_minutes)) at time zone 'UTC';
      while s < window_end loop
      e := least(s + interval '1 hour',window_end);
      if s > now() and not exists(select 1 from public.mentor_slots where mentor_id=p_mentor and starts_at < e and ends_at > s) then
        insert into public.mentor_slots(mentor_id,starts_at,ends_at,schedule_generated) values(p_mentor,s,e,true);
      end if;
      s := e;
      end loop;
    end loop;
  end loop;
end;
$$;
revoke all on function public.generate_weekly_mentor_slots(uuid) from public,anon,authenticated;

create or replace function public.available_mentor_slots(p_mentor uuid)
returns table(id uuid, starts_at timestamptz, ends_at timestamptz)
language plpgsql volatile security definer set search_path = '' as $$
begin
 if not public.is_student_account() or not public.is_approved_tutor(p_mentor) then return; end if;
 perform public.generate_weekly_mentor_slots(p_mentor);
 return query
 select nearest.id,nearest.starts_at,nearest.ends_at from (
   select s.id,s.starts_at,s.ends_at,
     extract(isodow from s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::integer as weekday,
     dense_rank() over(partition by extract(isodow from s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))
       order by (s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::date) as occurrence
   from public.mentor_slots s join public.tutor_profiles t on t.user_id=s.mentor_id
   where s.mentor_id=p_mentor and s.starts_at>now()
   and (jsonb_array_length(t.weekly_availability)=0 or exists(
     select 1 from jsonb_array_elements(t.weekly_availability) w
     where (w->>'day')::integer = extract(isodow from s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::integer
       and (s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::time >= make_time((w->>'start')::integer/60,(w->>'start')::integer%60,0)
       and s.ends_at <= ((s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::date::timestamp + make_interval(mins=>(w->>'end')::integer-t.utc_offset_minutes)) at time zone 'UTC'))
   and not exists(select 1 from public.mentorship_requests r where r.slot_id=s.id
     and (r.status in ('accepted','completed') or r.learner_id=auth.uid()))
 ) nearest where nearest.occurrence=1 order by nearest.weekday,nearest.starts_at;
end;
$$;
-- Replace only automatically generated, unrequested future sessions.
delete from public.mentor_slots s where s.schedule_generated and s.starts_at>now()
 and not exists(select 1 from public.mentorship_requests r where r.slot_id=s.id);
do $$ declare m uuid; begin
 for m in select user_id from public.tutor_profiles loop perform public.generate_weekly_mentor_slots(m); end loop;
end $$;
commit;
notify pgrst, 'reload schema';
