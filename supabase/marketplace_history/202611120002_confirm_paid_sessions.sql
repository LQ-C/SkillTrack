begin;

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
      and (r.learner_id = auth.uid() or r.status in ('accepted','completed')))
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
  where slot_id = p_slot and learner_id = auth.uid();
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
    where slot_id = payment.session_slot_id and learner_id = auth.uid();
  end if;
end;
$$;

-- Resolve outstanding paid requests in booking order, preserving existing confirmations.
lock table public.mentorship_requests in share row exclusive mode;

with next_booking as (
  select distinct on (r.slot_id) r.id
  from public.mentorship_requests r
  join public.mentor_payments p on p.id = r.payment_order_id
  join public.mentor_slots s on s.id = r.slot_id
  where r.status = 'pending' and p.status = 'paid' and s.starts_at > now()
    and public.is_approved_tutor(r.mentor_id)
    and not exists (
      select 1 from public.mentorship_requests existing
      where existing.slot_id = r.slot_id and existing.status in ('accepted','completed')
    )
  order by r.slot_id, r.created_at, r.id
)
update public.mentorship_requests r
set status = 'accepted', updated_at = now()
from next_booking b where r.id = b.id;

-- Requests which could not be confirmed release legacy credits or reverse simulated session payments.
with declined as (
  update public.mentorship_requests set status = 'declined', updated_at = now()
  where status = 'pending'
  returning payment_order_id
)
update public.mentor_payments p set status = 'refunded'
from declined d
where p.id = d.payment_order_id and p.purchase_kind = 'session' and p.status = 'paid';

commit;
notify pgrst, 'reload schema';
