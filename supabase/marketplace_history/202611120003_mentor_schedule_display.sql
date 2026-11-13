create or replace function public.available_mentor_schedule(p_mentor uuid)
returns table (
  id uuid, starts_at timestamptz, ends_at timestamptz,
  utc_offset_minutes integer, window_start integer, window_end integer
)
language sql volatile security definer set search_path = '' as $$
  select s.id, s.starts_at, s.ends_at, t.utc_offset_minutes,
    (w.value->>'start')::integer, (w.value->>'end')::integer
  from public.available_mentor_slots(p_mentor) s
  join public.tutor_profiles t on t.user_id = p_mentor
  left join lateral (
    select value from jsonb_array_elements(t.weekly_availability)
    where (value->>'day')::integer = extract(isodow from
      (s.starts_at at time zone 'UTC') + make_interval(mins => t.utc_offset_minutes))
    limit 1
  ) w on true
  order by s.starts_at;
$$;

revoke all on function public.available_mentor_schedule(uuid) from public, anon;
grant execute on function public.available_mentor_schedule(uuid) to authenticated;
notify pgrst, 'reload schema';
