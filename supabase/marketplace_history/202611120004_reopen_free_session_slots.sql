begin;

-- Keep cancelled/declined bookings in history without blocking a new booking.
alter table public.mentorship_requests drop constraint mentorship_requests_slot_id_learner_id_key;
create unique index one_active_booking_per_student_slot
  on public.mentorship_requests (slot_id, learner_id)
  where status in ('pending','accepted','completed');

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
      if s > now() and not exists(select 1 from public.mentor_slots where mentor_id=p_mentor and starts_at = s and ends_at = e) then
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
       and mod(
         extract(epoch from ((s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::time
           - make_time((w->>'start')::integer/60,(w->>'start')::integer%60,0)))::integer,
         3600
       ) = 0
       and s.ends_at = least(s.starts_at + interval '1 hour', ((s.starts_at at time zone 'UTC' + make_interval(mins=>t.utc_offset_minutes))::date::timestamp + make_interval(mins=>(w->>'end')::integer-t.utc_offset_minutes)) at time zone 'UTC')))
   and not exists (
     select 1 from public.mentorship_requests booking
     join public.mentor_slots occupied on occupied.id = booking.slot_id
     where occupied.mentor_id = p_mentor and occupied.id <> s.id
       and occupied.starts_at < s.ends_at and occupied.ends_at > s.starts_at
       and booking.status in ('accepted','completed')
   )
   and not exists(select 1 from public.mentorship_requests r where r.slot_id=s.id
     and (r.status in ('accepted','completed') or (r.learner_id=auth.uid() and r.status='pending')))
 ) nearest where nearest.occurrence=1 order by nearest.weekday,nearest.starts_at;
end;
$$;
create or replace function public.request_mentorship_internal(p_slot uuid, p_message text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  target_mentor uuid;
  target_slot public.mentor_slots;
begin
  if not public.is_verified_account() then raise exception 'Verify your email first.'; end if;
  select mentor_id into target_mentor from public.mentor_slots where id = p_slot;
  if not found then raise exception 'This session is unavailable.'; end if;

  -- Serialize bookings for the mentor, including bookings on overlapping older slots.
  perform 1 from public.tutor_profiles where user_id = target_mentor for update;
  select * into target_slot from public.mentor_slots where id = p_slot for update;
  if not found or target_slot.starts_at <= now()
    or not public.is_approved_tutor(target_slot.mentor_id)
    or target_slot.mentor_id = auth.uid()
  then raise exception 'This session is unavailable.'; end if;

  if exists (
    select 1 from public.mentorship_requests booking
    join public.mentor_slots occupied on occupied.id = booking.slot_id
    where occupied.mentor_id = target_slot.mentor_id
      and occupied.starts_at < target_slot.ends_at
      and occupied.ends_at > target_slot.starts_at
      and booking.status in ('accepted','completed')
  ) then raise exception 'This session is already booked.'; end if;

  insert into public.mentorship_requests(slot_id,mentor_id,learner_id,message)
  values(p_slot,target_slot.mentor_id,auth.uid(),trim(p_message));
end;
$$;

create or replace function public.prepare_session_checkout(p_slot uuid)
returns public.mentor_payments language plpgsql security definer set search_path = '' as $$
declare
  slot public.mentor_slots;
  order_row public.mentor_payments;
begin
  if not public.is_student_account() then raise exception 'Student account required.'; end if;
  perform 1 from public.profiles where id = auth.uid() for update;
  select * into slot from public.mentor_slots where id = p_slot;
  if not found or slot.starts_at <= now() or slot.mentor_id = auth.uid()
    or not public.is_approved_tutor(slot.mentor_id)
    or not exists (select 1 from public.tutor_profiles where user_id = slot.mentor_id and is_listed)
    or exists (select 1 from public.mentorship_requests r where r.slot_id = p_slot
      and ((r.learner_id = auth.uid() and r.status = 'pending') or r.status in ('accepted','completed')))
  then raise exception 'This session is unavailable.'; end if;
  if not public.has_mentor_library_access(slot.mentor_id, auth.uid()) then
    raise exception 'Buy this mentor’s learning materials before booking a session.';
  end if;
  select * into order_row from public.mentor_payments
  where session_slot_id = p_slot and learner_id = auth.uid()
    and purchase_kind = 'session' and status = 'pending';
  if found then return order_row; end if;
  insert into public.mentor_payments
    (mentor_id, learner_id, mentor_name, learner_name, amount, currency, purchase_kind, session_slot_id)
  select m.id, l.id, m.full_name, l.full_name, 300, 'myr', 'session', p_slot
  from public.profiles m cross join public.profiles l
  where m.id = slot.mentor_id and l.id = auth.uid() returning * into order_row;
  return order_row;
end;
$$;

-- Existing package credits still work through the original booking entry point.
create or replace function public.request_mentorship(p_slot uuid, p_message text)
returns void language plpgsql security definer set search_path = '' as $$
declare mentor uuid; credit uuid;
begin
  if not public.is_student_account() then raise exception 'Student account required.'; end if;
  perform 1 from public.profiles where id = auth.uid() for update;
  select mentor_id into mentor from public.mentor_slots where id = p_slot;
  if not public.has_mentor_library_access(mentor, auth.uid()) then
    raise exception 'Buy this mentor’s learning materials before booking a session.';
  end if;
  select p.id into credit from public.mentor_payments p
  where p.mentor_id = mentor and p.learner_id = auth.uid()
    and p.status = 'paid' and p.purchase_kind = 'legacy'
    and not exists (select 1 from public.mentorship_requests r
      where r.payment_order_id = p.id and r.status in ('pending','accepted','completed'))
  order by p.paid_at, p.id limit 1 for update;
  if not found then raise exception 'Pay for this session to submit a request.'; end if;
  perform public.request_mentorship_internal(p_slot, p_message);
  update public.mentorship_requests set payment_order_id = credit, status = 'accepted', updated_at = now()
  where slot_id = p_slot and learner_id = auth.uid() and status = 'pending';
end;
$$;

create or replace function public.complete_demo_mentor_payment(p_order uuid, p_result text)
returns void language plpgsql security definer set search_path = '' as $$
declare payment public.mentor_payments;
begin
  if not public.is_student_account() then raise exception 'Student account required.'; end if;
  if p_result is null or p_result not in ('success','failed','cancelled') then
    raise exception 'Choose a valid payment outcome.';
  end if;
  perform 1 from public.profiles where id = auth.uid() for update;
  -- Match schedule publishing's lock order before locking an order linked to a slot.
  if p_result = 'success' then
    perform 1 from public.tutor_profiles t
    join public.mentor_payments p on p.mentor_id = t.user_id
    where p.id = p_order and p.learner_id = auth.uid() and p.purchase_kind = 'session'
    for update of t;
  end if;
  select * into payment from public.mentor_payments
  where id = p_order and learner_id = auth.uid() for update;
  if not found or not payment.is_test or payment.provider <> 'demo'
    or payment.checkout_session_id is not null then raise exception 'Payment not found.'; end if;
  if payment.status = 'paid' then return; end if;
  if payment.status <> 'pending' then raise exception 'Start a new checkout to try again.'; end if;
  if p_result = 'success' then
    if not public.is_approved_tutor(payment.mentor_id) then
      raise exception 'This mentor is no longer available.';
    end if;
    if payment.purchase_kind = 'session' then
      if not public.has_mentor_library_access(payment.mentor_id, auth.uid()) then
        raise exception 'Buy this mentor’s learning materials before booking a session.';
      end if;
      perform public.request_mentorship_internal(payment.session_slot_id, 'Mentorship session requested.');

    end if;
  end if;
  update public.mentor_payments
  set status = case when p_result = 'success' then 'paid' else p_result end,
      paid_at = case when p_result = 'success' then now() else null end
  where id = p_order;
  if p_result = 'success' and payment.purchase_kind = 'session' then
    update public.mentorship_requests
    set payment_order_id = payment.id, status = 'accepted', updated_at = now()
    where slot_id = payment.session_slot_id and learner_id = auth.uid() and status = 'pending';
  end if;
end;
$$;

commit;
notify pgrst, 'reload schema';
