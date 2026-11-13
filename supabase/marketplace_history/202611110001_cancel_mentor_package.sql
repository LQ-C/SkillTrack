begin;

create or replace function public.cancel_mentor_package(p_mentor uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_student_account() then
    raise exception 'Use a verified Student account to cancel a mentor package.';
  end if;

  perform 1 from public.profiles where id = auth.uid() for update;

  -- Keep the original amount and paid_at for payment history.
  update public.mentor_payments
  set status = 'cancelled'
  where learner_id = auth.uid() and mentor_id = p_mentor
    and provider = 'demo' and status in ('paid', 'pending');

  update public.mentorship_requests r
  set status = 'cancelled', updated_at = now()
  from public.mentor_payments p, public.mentor_slots s
  where r.payment_order_id = p.id and r.slot_id = s.id
    and p.learner_id = auth.uid() and p.mentor_id = p_mentor
    and p.provider = 'demo' and p.status = 'cancelled'
    and r.status in ('pending', 'accepted') and s.starts_at > now();
end;
$$;

revoke all on function public.cancel_mentor_package(uuid) from public, anon;
grant execute on function public.cancel_mentor_package(uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
