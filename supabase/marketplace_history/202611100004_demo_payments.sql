-- In-app simulation only. No Stripe account, card data, charge or payout.
begin;
alter table public.mentor_payments add column provider text not null default 'demo' check(provider='demo');
alter table public.mentor_payments drop constraint mentor_payments_status_check;
alter table public.mentor_payments add constraint mentor_payments_status_check
check(status in ('pending','paid','failed','expired','refunded','cancelled'));

create function public.complete_demo_mentor_payment(p_order uuid,p_result text) returns void
language plpgsql security definer set search_path='' as $$
declare payment public.mentor_payments;
begin
 if not public.is_student_account() then raise exception 'Use a verified Student account for demo payments.'; end if;
 if p_result is null or p_result not in ('success','failed','cancelled') then raise exception 'Choose a valid demo payment outcome.'; end if;
 select * into payment from public.mentor_payments where id=p_order and learner_id=auth.uid() for update;
 if not found or not payment.is_test or payment.provider<>'demo' or payment.checkout_session_id is not null then
   raise exception 'Demo payment not found.';
 end if;
 if payment.status='paid' then return; end if;
 if payment.status<>'pending' then raise exception 'Start a new demo payment to try again.'; end if;
 if not public.is_approved_tutor(payment.mentor_id) then raise exception 'This mentor is no longer available.'; end if;
 update public.mentor_payments set status=case when p_result='success' then 'paid' else p_result end,
 paid_at=case when p_result='success' then now() else null end where id=p_order;
end;
$$;
revoke all on function public.complete_demo_mentor_payment(uuid,text) from public,anon;
grant execute on function public.complete_demo_mentor_payment(uuid,text) to authenticated;
commit;
notify pgrst,'reload schema';
