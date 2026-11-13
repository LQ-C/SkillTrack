-- Apply AFTER private mentor libraries. Stripe test mode only; no real charges/payouts.
begin;
create table public.mentor_payment_offers (
  mentor_id uuid primary key references public.profiles(id) on delete cascade,
  amount integer not null check(amount between 200 and 1000000),
  currency text not null default 'myr' check(currency='myr'),
  updated_at timestamptz not null default now()
);
alter table public.mentor_payment_offers enable row level security;
revoke all on public.mentor_payment_offers from public,anon,authenticated;
grant select on public.mentor_payment_offers to authenticated;
create policy "Read mentor package prices" on public.mentor_payment_offers for select to authenticated
using(public.is_verified_account() and (mentor_id=auth.uid() or (public.is_student_account() and public.is_approved_tutor(mentor_id))));

create table public.mentor_payments (
  id uuid primary key default gen_random_uuid(),
  mentor_id uuid not null references public.profiles(id) on delete cascade,
  learner_id uuid not null references public.profiles(id) on delete cascade,
  mentor_name text not null,
  learner_name text not null,
  amount integer not null check(amount between 200 and 1000000),
  currency text not null check(currency='myr'),
  is_test boolean not null default true check(is_test),
  status text not null default 'pending' check(status in ('pending','paid','failed','expired','refunded')),
  checkout_session_id text unique,
  checkout_url text,
  payment_intent_id text unique,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  check(mentor_id<>learner_id)
);
create unique index one_pending_mentor_checkout on public.mentor_payments(mentor_id,learner_id) where status='pending';
alter table public.mentor_payments enable row level security;
revoke all on public.mentor_payments from public,anon,authenticated;
grant select on public.mentor_payments to authenticated;
create policy "Read participant test payments" on public.mentor_payments for select to authenticated
using(public.is_verified_account() and auth.uid() in (mentor_id,learner_id));
alter table public.mentorship_requests add column payment_order_id uuid references public.mentor_payments(id) on delete set null;
create unique index one_active_request_per_payment on public.mentorship_requests(payment_order_id)
where payment_order_id is not null and status in ('pending','accepted','completed');

create function public.save_mentor_payment_offer(p_amount integer) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not public.can_author_content() then raise exception 'Only mentors can set package prices.'; end if;
 if p_amount is null or p_amount not between 200 and 1000000 then raise exception 'Enter a package price from RM2.00 to RM10,000.00.'; end if;
 insert into public.mentor_payment_offers(mentor_id,amount) values(auth.uid(),p_amount)
 on conflict(mentor_id) do update set amount=excluded.amount,updated_at=now();
end;
$$;

create function public.mentor_payment_access(p_mentor uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.is_student_account() then raise exception 'Student account required.'; end if;
 return jsonb_build_object('materials',exists(select 1 from public.mentor_payments where mentor_id=p_mentor and learner_id=auth.uid() and status='paid'),
 'credits',(select count(*) from public.mentor_payments p where p.mentor_id=p_mentor and p.learner_id=auth.uid() and p.status='paid'
 and not exists(select 1 from public.mentorship_requests r where r.payment_order_id=p.id and r.status in ('pending','accepted','completed'))));
end;
$$;

create function public.prepare_mentor_checkout(p_mentor uuid) returns public.mentor_payments
language plpgsql security definer set search_path='' as $$
declare offer public.mentor_payment_offers; result public.mentor_payments;
begin
 if not public.is_student_account() or p_mentor=auth.uid() or not public.is_approved_tutor(p_mentor)
   or not exists(select 1 from public.tutor_profiles where user_id=p_mentor and is_listed) then
   raise exception 'Choose an available mentor using a student account.';
 end if;
 -- Serialize purchases for this student (including concurrent device requests).
 perform 1 from public.profiles where id=auth.uid() for update;
 if exists(select 1 from public.mentor_payments p where p.mentor_id=p_mentor and p.learner_id=auth.uid() and p.status='paid'
   and not exists(select 1 from public.mentorship_requests r where r.payment_order_id=p.id and r.status in ('pending','accepted','completed'))) then
   raise exception 'You already have an unused session credit with this mentor.';
 end if;
 select * into result from public.mentor_payments where mentor_id=p_mentor and learner_id=auth.uid() and status='pending';
 if found then return result; end if;
 select * into offer from public.mentor_payment_offers where mentor_id=p_mentor;
 if not found then raise exception 'This mentor has not set a package price yet.'; end if;
 insert into public.mentor_payments(mentor_id,learner_id,mentor_name,learner_name,amount,currency)
 select p_mentor,auth.uid(),m.full_name,l.full_name,offer.amount,offer.currency from public.profiles m,public.profiles l
 where m.id=p_mentor and l.id=auth.uid() returning * into result;
 return result;
end;
$$;

create function public.record_mentor_checkout(p_order uuid,p_session text,p_url text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_session not like 'cs_test_%' or p_url not like 'https://checkout.stripe.com/%' then raise exception 'Test checkout required.'; end if;
 update public.mentor_payments set checkout_session_id=p_session,checkout_url=p_url where id=p_order and status='pending'
 and (checkout_session_id is null or checkout_session_id=p_session);
 if not found then raise exception 'Checkout order no longer available.'; end if;
end;
$$;

create function public.settle_mentor_payment(p_order uuid,p_session text,p_intent text,p_amount integer,p_currency text,p_status text) returns void
language plpgsql security definer set search_path='' as $$
declare payment public.mentor_payments;
begin
 select * into payment from public.mentor_payments where id=p_order for update;
 if not found or payment.checkout_session_id is distinct from p_session or payment.amount is distinct from p_amount
   or payment.currency is distinct from p_currency or p_session not like 'cs_test_%' then raise exception 'Payment details do not match the order.'; end if;
 if p_status not in ('paid','failed','expired') then raise exception 'Invalid payment status.'; end if;
 if payment.status in ('paid','refunded') then return; end if;
 if p_status='paid' and (p_intent is null or p_intent not like 'pi_%') then raise exception 'Payment intent missing.'; end if;
 update public.mentor_payments set status=p_status,payment_intent_id=case when p_status='paid' then p_intent else payment_intent_id end,
 paid_at=case when p_status='paid' then now() else paid_at end where id=p_order;
end;
$$;
create function public.refund_mentor_payment(p_intent text,p_amount integer,p_currency text) returns void
language plpgsql security definer set search_path='' as $$
begin
 update public.mentor_payments set status='refunded' where payment_intent_id=p_intent and amount=p_amount and currency=p_currency and status='paid';
end;
$$;

create or replace function public.request_mentorship(p_slot uuid,p_message text) returns void
language plpgsql security definer set search_path='' as $$
declare mentor uuid; credit uuid;
begin
 if not public.is_student_account() then raise exception 'Only student accounts can request a mentor.'; end if;
 select mentor_id into mentor from public.mentor_slots where id=p_slot;
 if not found then raise exception 'This session is unavailable.'; end if;
 select p.id into credit from public.mentor_payments p where p.mentor_id=mentor and p.learner_id=auth.uid() and p.status='paid'
 and not exists(select 1 from public.mentorship_requests r where r.payment_order_id=p.id and r.status in ('pending','accepted','completed'))
 order by p.paid_at,p.id limit 1 for update of p skip locked;
 if not found then raise exception 'Purchase a mentor package before booking. One payment includes one session credit.'; end if;
 perform public.request_mentorship_internal(p_slot,p_message);
 update public.mentorship_requests set payment_order_id=credit where slot_id=p_slot and learner_id=auth.uid();
end;
$$;

create function public.check_paid_request_acceptance() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status='accepted' and new.payment_order_id is not null and not exists(select 1 from public.mentor_payments where id=new.payment_order_id and status='paid') then
   raise exception 'This session payment is no longer valid.';
 end if;
 return new;
end;
$$;
create trigger check_payment_before_accept before update of status on public.mentorship_requests for each row execute function public.check_paid_request_acceptance();

-- Verified Stripe payment replaces manual grants. Material access does not require
-- that the purchased session has already been booked or accepted.
create or replace function public.has_mentor_library_access(p_mentor uuid,p_learner uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.mentor_payments where mentor_id=p_mentor and learner_id=p_learner and status='paid');
$$;

revoke all on function public.save_mentor_payment_offer(integer),public.mentor_payment_access(uuid),public.prepare_mentor_checkout(uuid) from public,anon;
grant execute on function public.save_mentor_payment_offer(integer),public.mentor_payment_access(uuid),public.prepare_mentor_checkout(uuid) to authenticated;
revoke all on function public.record_mentor_checkout(uuid,text,text),public.settle_mentor_payment(uuid,text,text,integer,text,text),public.refund_mentor_payment(text,integer,text),public.check_paid_request_acceptance() from public,anon,authenticated;
grant execute on function public.record_mentor_checkout(uuid,text,text),public.settle_mentor_payment(uuid,text,text,integer,text,text),public.refund_mentor_payment(text,integer,text) to service_role;
commit;
notify pgrst,'reload schema';
