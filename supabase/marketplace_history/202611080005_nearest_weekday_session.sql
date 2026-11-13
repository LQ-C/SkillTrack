-- Return one nearest available occurrence per selected weekday.
begin;
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
     row_number() over(partition by extract(isodow from s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))
       order by s.starts_at,s.id) as occurrence
   from public.mentor_slots s join public.tutor_profiles t on t.user_id=s.mentor_id
   where s.mentor_id=p_mentor and s.starts_at>now()
   and (jsonb_array_length(t.weekly_availability)=0 or exists(
     select 1 from jsonb_array_elements(t.weekly_availability) w
     where (w->>'day')::integer = extract(isodow from s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::integer
       and (w->>'start')::integer = extract(hour from s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::integer*60
         + extract(minute from s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::integer
       and s.ends_at-s.starts_at=make_interval(mins=>(w->>'end')::integer-(w->>'start')::integer)))
   and not exists(select 1 from public.mentorship_requests r where r.slot_id=s.id
     and (r.status in ('accepted','completed') or r.learner_id=auth.uid()))
 ) nearest where nearest.occurrence=1 order by nearest.weekday;
end;
$$;
commit;
notify pgrst, 'reload schema';
