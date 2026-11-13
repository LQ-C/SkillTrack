begin;

alter table public.mentor_payments
  add column purchase_kind text not null default 'legacy',
  add column session_slot_id uuid references public.mentor_slots(id) on delete set null,
  drop constraint mentor_payments_amount_check,
  add constraint mentor_payments_purchase_price check (
    (purchase_kind = 'session' and amount between 100 and 500)
    or (purchase_kind in ('legacy', 'materials') and amount between 200 and 1000000
        and session_slot_id is null)
  );

-- Old paid packages retain both of their original benefits.
update public.mentor_payments set status = 'expired'
where status = 'pending' and checkout_session_id is null;

drop index public.one_pending_mentor_checkout;
create unique index one_pending_material_checkout
  on public.mentor_payments (mentor_id, learner_id)
  where status = 'pending' and purchase_kind in ('materials', 'legacy');
create unique index one_pending_session_checkout
  on public.mentor_payments (session_slot_id, learner_id)
  where status = 'pending' and purchase_kind = 'session';

create or replace function public.has_mentor_library_access(p_mentor uuid, p_learner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.mentor_payments
    where mentor_id = p_mentor and learner_id = p_learner and status = 'paid'
      and purchase_kind in ('legacy', 'materials')
  );
$$;

create or replace function public.mentor_payment_access(p_mentor uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_student_account() then raise exception 'Student account required.'; end if;
  return jsonb_build_object(
    'materials', public.has_mentor_library_access(p_mentor, auth.uid()),
    'credits', (select count(*) from public.mentor_payments p
      where p.mentor_id = p_mentor and p.learner_id = auth.uid()
        and p.status = 'paid' and p.purchase_kind = 'legacy'
        and not exists (select 1 from public.mentorship_requests r
          where r.payment_order_id = p.id and r.status in ('pending','accepted','completed')))
  );
end;
$$;

create or replace function public.prepare_mentor_checkout(p_mentor uuid)
returns public.mentor_payments language plpgsql security definer set search_path = '' as $$
declare order_row public.mentor_payments;
begin
  if not public.is_student_account() or p_mentor = auth.uid()
    or not public.is_approved_tutor(p_mentor)
    or not exists (select 1 from public.tutor_profiles where user_id = p_mentor and is_listed)
  then raise exception 'Choose an available mentor using a student account.'; end if;
  perform 1 from public.profiles where id = auth.uid() for update;
  if public.has_mentor_library_access(p_mentor, auth.uid()) then
    raise exception 'You already have access to these materials.';
  end if;
  select * into order_row from public.mentor_payments
  where mentor_id = p_mentor and learner_id = auth.uid()
    and status = 'pending' and purchase_kind in ('legacy', 'materials');
  if found then return order_row; end if;
  insert into public.mentor_payments
    (mentor_id, learner_id, mentor_name, learner_name, amount, currency, purchase_kind)
  select m.id, l.id, m.full_name, l.full_name, o.amount, o.currency, 'materials'
  from public.mentor_payment_offers o
  join public.profiles m on m.id = o.mentor_id
  join public.profiles l on l.id = auth.uid()
  where o.mentor_id = p_mentor returning * into order_row;
  if not found then raise exception 'This mentor has not set a materials price yet.'; end if;
  return order_row;
end;
$$;

create function public.prepare_session_checkout(p_slot uuid)
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
  select p.id into credit from public.mentor_payments p
  where p.mentor_id = mentor and p.learner_id = auth.uid()
    and p.status = 'paid' and p.purchase_kind = 'legacy'
    and not exists (select 1 from public.mentorship_requests r
      where r.payment_order_id = p.id and r.status in ('pending','accepted','completed'))
  order by p.paid_at, p.id limit 1 for update;
  if not found then raise exception 'Pay for this session to submit a request.'; end if;
  perform public.request_mentorship_internal(p_slot, p_message);
  update public.mentorship_requests set payment_order_id = credit
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
      perform public.request_mentorship_internal(payment.session_slot_id, 'Mentorship session requested.');
      update public.mentorship_requests set payment_order_id = payment.id
      where slot_id = payment.session_slot_id and learner_id = auth.uid();
    end if;
  end if;
  update public.mentor_payments
  set status = case when p_result = 'success' then 'paid' else p_result end,
      paid_at = case when p_result = 'success' then now() else null end
  where id = p_order;
end;
$$;

create or replace function public.cancel_mentor_package(p_mentor uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_student_account() then raise exception 'Student account required.'; end if;
  perform 1 from public.profiles where id = auth.uid() for update;
  update public.mentor_payments set status = 'cancelled'
  where learner_id = auth.uid() and mentor_id = p_mentor and provider = 'demo'
    and purchase_kind in ('legacy', 'materials') and status in ('paid', 'pending');
  update public.mentorship_requests r set status = 'cancelled', updated_at = now()
  from public.mentor_payments p, public.mentor_slots s
  where r.payment_order_id = p.id and r.slot_id = s.id
    and p.learner_id = auth.uid() and p.mentor_id = p_mentor and p.provider = 'demo'
    and p.purchase_kind = 'legacy' and p.status = 'cancelled'
    and r.status in ('pending', 'accepted') and s.starts_at > now();
end;
$$;

revoke all on function public.prepare_session_checkout(uuid) from public, anon;
grant execute on function public.prepare_session_checkout(uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
