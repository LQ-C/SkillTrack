-- Combined SkillTrack + Marketplace schema-only bootstrap.
-- Target: a fresh Supabase integration database. Not an in-place/data migration.
-- profiles and paid learning_resources follow the Marketplace export.
-- No rows, buckets, Edge Functions or secrets are installed by this file.
BEGIN;
DO $guard$
BEGIN
  IF to_regclass('public.profiles') IS NOT NULL
     OR to_regclass('public.projects') IS NOT NULL
     OR to_regclass('public.learning_resources') IS NOT NULL THEN
    RAISE EXCEPTION 'Use a fresh Supabase database: existing application tables detected.';
  END IF;
END;
$guard$;
-- Avoid inheriting target-project grants that could weaken explicit source ACLs.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

-- SOURCE: Marketplace

SET statement_timeout = 0;

SET lock_timeout = 0;

SET idle_in_transaction_session_timeout = 0;

SET client_encoding = 'UTF8';

SET standard_conforming_strings = on;

SELECT pg_catalog.set_config('search_path', '', false);

SET check_function_bodies = false;

SET xmloption = content;

SET client_min_messages = warning;

SET row_security = off;

COMMENT ON SCHEMA "public" IS 'standard public schema';

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

CREATE OR REPLACE FUNCTION "public"."available_mentor_schedule"("p_mentor" "uuid") RETURNS TABLE("id" "uuid", "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "utc_offset_minutes" integer, "window_start" integer, "window_end" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."available_mentor_schedule"("p_mentor" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."available_mentor_slots"("p_mentor" "uuid") RETURNS TABLE("id" "uuid", "starts_at" timestamp with time zone, "ends_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."available_mentor_slots"("p_mentor" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."can_author_content"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select public.is_verified_account() and exists (
    select 1 from public.profiles where id = (select auth.uid()) and role = 'mentor');
$$;

ALTER FUNCTION "public"."can_author_content"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."can_publish_content"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select public.can_author_content() and exists (
    select 1 from public.content_publishers where user_id = (select auth.uid()));
$$;

ALTER FUNCTION "public"."can_publish_content"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."can_read_mentor_resource"("p_author" "uuid", "p_status" "text", "p_hidden" boolean) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
 select public.is_verified_account() and (
   (p_author=auth.uid() and public.can_author_content()) or
   (public.is_student_account() and p_status='published' and not p_hidden
     and public.is_content_publisher(p_author)
     and public.has_mentor_library_access(p_author,auth.uid())));
$$;

ALTER FUNCTION "public"."can_read_mentor_resource"("p_author" "uuid", "p_status" "text", "p_hidden" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."cancel_mentor_package"("p_mentor" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."cancel_mentor_package"("p_mentor" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."check_paid_request_acceptance"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 if new.status='accepted' and new.payment_order_id is not null and not exists(select 1 from public.mentor_payments where id=new.payment_order_id and status='paid') then
   raise exception 'This session payment is no longer valid.';
 end if;
 return new;
end;
$$;

ALTER FUNCTION "public"."check_paid_request_acceptance"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."complete_demo_mentor_payment"("p_order" "uuid", "p_result" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."complete_demo_mentor_payment"("p_order" "uuid", "p_result" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."delete_mentor_slot"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.is_verified_account() then raise exception 'Sign in first.'; end if;
  perform 1 from public.mentor_slots where id = p_id and mentor_id = auth.uid() for update;
  if not found then raise exception 'Slot not found.'; end if;
  if exists(select 1 from public.mentorship_requests where slot_id = p_id) then
    raise exception 'Slots with requests must be retained for session history.'; end if;
  delete from public.mentor_slots where id = p_id;
end;
$$;

ALTER FUNCTION "public"."delete_mentor_slot"("p_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enable_tutor_profile"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.is_verified_account() then raise exception 'Verify your email first.'; end if;
  update public.profiles set role = 'mentor' where id = auth.uid();
end;
$$;

ALTER FUNCTION "public"."enable_tutor_profile"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."generate_weekly_mentor_slots"("p_mentor" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."generate_weekly_mentor_slots"("p_mentor" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."handle_new_account"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  insert into public.profiles(id,full_name,date_of_birth,role)
  values(new.id,trim(new.raw_user_meta_data->>'full_name'),
    (new.raw_user_meta_data->>'date_of_birth')::date,
    coalesce(new.raw_user_meta_data->>'role','student'));
  return new;
end;
$$;

ALTER FUNCTION "public"."handle_new_account"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."has_mentor_library_access"("p_mentor" "uuid", "p_learner" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1 from public.mentor_payments
    where mentor_id = p_mentor and learner_id = p_learner and status = 'paid'
      and purchase_kind in ('legacy', 'materials')
  );
$$;

ALTER FUNCTION "public"."has_mentor_library_access"("p_mentor" "uuid", "p_learner" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."has_tutor_qualification"("p_path" "text", "p_user" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select p_path <> '' and split_part(p_path,'/',1) = p_user::text
    and exists(select 1 from storage.objects where bucket_id = 'mentor-qualifications'
      and name = p_path and metadata->>'mimetype' in ('application/pdf','image/jpeg','image/png')
      and (metadata->>'size')::bigint between 1 and 10485760);
$$;

ALTER FUNCTION "public"."has_tutor_qualification"("p_path" "text", "p_user" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."is_approved_tutor"("candidate" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists(select 1 from public.tutor_profiles t
    join public.profiles p on p.id = t.user_id
    join auth.users u on u.id = p.id
    where p.id = candidate and p.role = 'mentor' and u.email_confirmed_at is not null);
$$;

ALTER FUNCTION "public"."is_approved_tutor"("candidate" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."is_content_publisher"("candidate" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (select 1 from public.content_publishers cp
    join public.profiles p on p.id = cp.user_id
    where cp.user_id = candidate and p.role = 'mentor');
$$;

ALTER FUNCTION "public"."is_content_publisher"("candidate" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."is_student_account"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select public.is_verified_account() and exists(select 1 from public.profiles
    where id = auth.uid() and role = 'student');
$$;

ALTER FUNCTION "public"."is_student_account"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."is_verified_account"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists(select 1 from auth.users
    where id = (select auth.uid()) and email_confirmed_at is not null);
$$;

ALTER FUNCTION "public"."is_verified_account"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."mentor_payment_access"("p_mentor" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."mentor_payment_access"("p_mentor" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."my_learner_library_access"("p_learner" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 if not public.can_author_content() then raise exception 'Only mentors can manage learner access.'; end if;
 return public.has_mentor_library_access(auth.uid(),p_learner);
end;
$$;

ALTER FUNCTION "public"."my_learner_library_access"("p_learner" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."my_mentorship_sessions"() RETURNS TABLE("id" "uuid", "mentor_id" "uuid", "learner_id" "uuid", "mentor_name" "text", "learner_name" "text", "message" "text", "status" "text", "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "reviewed" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select r.id,r.mentor_id,r.learner_id,mp.full_name,lp.full_name,r.message,r.status,
    s.starts_at,s.ends_at,exists(select 1 from public.mentor_reviews v where v.request_id = r.id)
  from public.mentorship_requests r join public.mentor_slots s on s.id = r.slot_id
    join public.profiles mp on mp.id = r.mentor_id join public.profiles lp on lp.id = r.learner_id
  where public.is_verified_account() and auth.uid() in (r.mentor_id,r.learner_id)
  order by s.starts_at desc;
$$;

ALTER FUNCTION "public"."my_mentorship_sessions"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";

CREATE TABLE IF NOT EXISTS "public"."mentor_payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "mentor_id" "uuid" NOT NULL,
    "learner_id" "uuid" NOT NULL,
    "mentor_name" "text" NOT NULL,
    "learner_name" "text" NOT NULL,
    "amount" integer NOT NULL,
    "currency" "text" NOT NULL,
    "is_test" boolean DEFAULT true NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "checkout_session_id" "text",
    "checkout_url" "text",
    "payment_intent_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "paid_at" timestamp with time zone,
    "provider" "text" DEFAULT 'demo'::"text" NOT NULL,
    "purchase_kind" "text" DEFAULT 'legacy'::"text" NOT NULL,
    "session_slot_id" "uuid",
    CONSTRAINT "mentor_payments_check" CHECK (("mentor_id" <> "learner_id")),
    CONSTRAINT "mentor_payments_currency_check" CHECK (("currency" = 'myr'::"text")),
    CONSTRAINT "mentor_payments_is_test_check" CHECK ("is_test"),
    CONSTRAINT "mentor_payments_provider_check" CHECK (("provider" = 'demo'::"text")),
    CONSTRAINT "mentor_payments_purchase_price" CHECK (((("purchase_kind" = 'session'::"text") AND (("amount" >= 100) AND ("amount" <= 500))) OR (("purchase_kind" = ANY (ARRAY['legacy'::"text", 'materials'::"text"])) AND (("amount" >= 200) AND ("amount" <= 1000000)) AND ("session_slot_id" IS NULL)))),
    CONSTRAINT "mentor_payments_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'paid'::"text", 'failed'::"text", 'expired'::"text", 'refunded'::"text", 'cancelled'::"text"])))
);

ALTER TABLE "public"."mentor_payments" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."prepare_mentor_checkout"("p_mentor" "uuid") RETURNS "public"."mentor_payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."prepare_mentor_checkout"("p_mentor" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."prepare_session_checkout"("p_slot" "uuid") RETURNS "public"."mentor_payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."prepare_session_checkout"("p_slot" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."publish_mentor_schedule"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_availability" "jsonb", "p_session_minutes" integer, "p_utc_offset" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
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
$_$;

ALTER FUNCTION "public"."publish_mentor_schedule"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_availability" "jsonb", "p_session_minutes" integer, "p_utc_offset" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."record_mentor_checkout"("p_order" "uuid", "p_session" "text", "p_url" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 if p_session not like 'cs_test_%' or p_url not like 'https://checkout.stripe.com/%' then raise exception 'Test checkout required.'; end if;
 update public.mentor_payments set checkout_session_id=p_session,checkout_url=p_url where id=p_order and status='pending'
 and (checkout_session_id is null or checkout_session_id=p_session);
 if not found then raise exception 'Checkout order no longer available.'; end if;
end;
$$;

ALTER FUNCTION "public"."record_mentor_checkout"("p_order" "uuid", "p_session" "text", "p_url" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."refund_mentor_payment"("p_intent" "text", "p_amount" integer, "p_currency" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 update public.mentor_payments set status='refunded' where payment_intent_id=p_intent and amount=p_amount and currency=p_currency and status='paid';
end;
$$;

ALTER FUNCTION "public"."refund_mentor_payment"("p_intent" "text", "p_amount" integer, "p_currency" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."request_mentorship"("p_slot" "uuid", "p_message" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."request_mentorship"("p_slot" "uuid", "p_message" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."request_mentorship_internal"("p_slot" "uuid", "p_message" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."request_mentorship_internal"("p_slot" "uuid", "p_message" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."require_tutor_qualification"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  new.verification_status := 'approved';
  new.review_note := '';
  new.reviewed_at := null;
  return new;
end;
$$;

ALTER FUNCTION "public"."require_tutor_qualification"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."respond_mentorship"("p_request" "uuid", "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare r public.mentorship_requests; s public.mentor_slots;
begin
  if not public.is_verified_account() then raise exception 'Sign in first.'; end if;
  -- Always lock slot before request, matching request_mentorship's lock order.
  select sl.* into s from public.mentor_slots sl join public.mentorship_requests mr
    on mr.slot_id = sl.id where mr.id = p_request for update of sl;
  select * into r from public.mentorship_requests where id = p_request for update;
  if not found or auth.uid() not in (r.mentor_id,r.learner_id) then raise exception 'Request not found.'; end if;
  if p_status in ('accepted','declined') and auth.uid() = r.mentor_id and r.status = 'pending' then
    if p_status = 'accepted' and (s.starts_at <= now() or not public.is_approved_tutor(r.mentor_id)) then
      raise exception 'Only approved mentors can accept future sessions.'; end if;
  elsif p_status = 'cancelled' and r.status in ('pending','accepted') and s.starts_at > now() then
    null;
  elsif p_status = 'completed' and auth.uid() = r.mentor_id and r.status = 'accepted' and s.ends_at <= now() then
    null;
  else raise exception 'This request cannot move to that status.';
  end if;
  update public.mentorship_requests set status = p_status, updated_at = now() where id = p_request;
  if p_status = 'accepted' then
    update public.mentorship_requests set status = 'declined', updated_at = now()
      where slot_id = r.slot_id and id <> r.id and status = 'pending';
  end if;
end;
$$;

ALTER FUNCTION "public"."respond_mentorship"("p_request" "uuid", "p_status" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."review_mentor"("p_request" "uuid", "p_rating" integer, "p_review" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare r public.mentorship_requests;
begin
  if not public.is_verified_account() then raise exception 'Sign in first.'; end if;
  select * into r from public.mentorship_requests where id = p_request for update;
  if not found or r.learner_id <> auth.uid() or r.status <> 'completed' then
    raise exception 'Only the learner from a completed session can leave feedback.'; end if;
  insert into public.mentor_reviews(request_id,mentor_id,learner_id,rating,review)
    values(r.id,r.mentor_id,auth.uid(),p_rating,trim(p_review));
end;
$$;

ALTER FUNCTION "public"."review_mentor"("p_request" "uuid", "p_rating" integer, "p_review" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_mentor_payment_offer"("p_amount" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 if not public.can_author_content() then raise exception 'Only mentors can set package prices.'; end if;
 if p_amount is null or p_amount not between 200 and 1000000 then raise exception 'Enter a package price from RM2.00 to RM10,000.00.'; end if;
 insert into public.mentor_payment_offers(mentor_id,amount) values(auth.uid(),p_amount)
 on conflict(mentor_id) do update set amount=excluded.amount,updated_at=now();
end;
$$;

ALTER FUNCTION "public"."save_mentor_payment_offer"("p_amount" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_mentor_slot"("p_id" "uuid", "p_start" timestamp with time zone, "p_end" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.is_verified_account() or not public.is_approved_tutor(auth.uid()) then
    raise exception 'Mentor approval is required to offer sessions.'; end if;
  -- Serialize edits and inserts for a mentor so overlapping times cannot race.
  perform 1 from public.tutor_profiles where user_id = auth.uid() for update;
  if p_start <= now() or p_end <= p_start or p_end > p_start + interval '8 hours' then
    raise exception 'Choose a future session lasting up to 8 hours.'; end if;
  if p_id is not null then
    perform 1 from public.mentor_slots where id = p_id and mentor_id = auth.uid() for update;
    if not found then raise exception 'Slot not found.'; end if;
    if exists(select 1 from public.mentorship_requests where slot_id = p_id) then
      raise exception 'This slot has requests. Keep it for the session history and create a new slot.'; end if;
  end if;
  if exists(select 1 from public.mentor_slots where mentor_id = auth.uid()
      and (p_id is null or id <> p_id) and starts_at < p_end and ends_at > p_start) then
    raise exception 'This time overlaps another availability slot.'; end if;
  if p_id is null then
    insert into public.mentor_slots(mentor_id,starts_at,ends_at) values(auth.uid(),p_start,p_end);
  else update public.mentor_slots set starts_at = p_start, ends_at = p_end where id = p_id; end if;
end;
$$;

ALTER FUNCTION "public"."save_mentor_slot"("p_id" "uuid", "p_start" timestamp with time zone, "p_end" timestamp with time zone) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_tutor_profile"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_submit" boolean, "p_qualification_path" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.can_author_content() then raise exception 'Choose Mentor in your profile first.'; end if;
  if char_length(trim(p_headline)) < 3 or char_length(trim(p_expertise)) < 3 then raise exception 'Add a headline and the skills you teach.'; end if;
  if p_submit and not exists(select 1 from public.tutor_profiles where user_id=auth.uid() and jsonb_array_length(weekly_availability)>0) then
    raise exception 'Choose your weekly availability before publishing.';
  end if;
  update public.tutor_profiles set headline=trim(p_headline),expertise=trim(p_expertise),experience=trim(p_experience),
    credential_url=trim(p_credential_url),teaching_preferences=trim(p_preferences),verification_status='approved',
    is_listed=case when p_submit then true else is_listed end,updated_at=now() where user_id=auth.uid();
  if not found then raise exception 'Create your mentor profile first.'; end if;
end;
$$;

ALTER FUNCTION "public"."save_tutor_profile"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_submit" boolean, "p_qualification_path" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."set_learner_library_access"("p_learner" "uuid", "p_grant" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 if not public.can_author_content() then raise exception 'Only mentors can manage learner access.'; end if;
 if p_grant then
   if not exists(select 1 from public.mentorship_requests where mentor_id=auth.uid() and learner_id=p_learner and status in ('accepted','completed')) then
     raise exception 'Accept a booking from this student before granting library access.';
   end if;
   insert into public.mentor_library_access(mentor_id,learner_id) values(auth.uid(),p_learner)
     on conflict(mentor_id,learner_id) do update set granted_at=now();
 else
   delete from public.mentor_library_access where mentor_id=auth.uid() and learner_id=p_learner;
 end if;
end;
$$;

ALTER FUNCTION "public"."set_learner_library_access"("p_learner" "uuid", "p_grant" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."settle_mentor_payment"("p_order" "uuid", "p_session" "text", "p_intent" "text", "p_amount" integer, "p_currency" "text", "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."settle_mentor_payment"("p_order" "uuid", "p_session" "text", "p_intent" "text", "p_amount" integer, "p_currency" "text", "p_status" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."stamp_resource"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  select full_name into new.author_name from public.profiles where id = new.author_id;
  new.updated_at = now();
  return new;
end;
$$;

ALTER FUNCTION "public"."stamp_resource"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."sync_open_mentor_role"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.role = 'mentor' then
    insert into public.tutor_profiles(user_id,verification_status)
    values(new.id,'approved') on conflict(user_id) do update
      set verification_status = 'approved', review_note = '', reviewed_at = null;
  else
    delete from public.content_publishers where user_id = new.id;
  end if;
  return new;
end;
$$;

ALTER FUNCTION "public"."sync_open_mentor_role"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."sync_tutor_publisher"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists(select 1 from public.profiles where id = new.user_id and role = 'mentor') then
    insert into public.content_publishers(user_id) values(new.user_id) on conflict do nothing;
  else
    delete from public.content_publishers where user_id = new.user_id;
  end if;
  return new;
end;
$$;

ALTER FUNCTION "public"."sync_tutor_publisher"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."touch_profile"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;

ALTER FUNCTION "public"."touch_profile"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."tutor_directory"() RETURNS TABLE("user_id" "uuid", "full_name" "text", "headline" "text", "expertise" "text", "teaching_preferences" "text", "average_rating" numeric, "review_count" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select t.user_id,p.full_name,t.headline,t.expertise,t.teaching_preferences,
    (select round(avg(r.rating),1) from public.mentor_reviews r where r.mentor_id = t.user_id),
    (select count(*) from public.mentor_reviews r where r.mentor_id = t.user_id)
  from public.tutor_profiles t join public.profiles p on p.id = t.user_id
  where public.is_student_account() and public.is_approved_tutor(t.user_id) and t.is_listed
  order by p.full_name,t.user_id;
$$;

ALTER FUNCTION "public"."tutor_directory"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."tutor_feedback"("p_mentor" "uuid") RETURNS TABLE("rating" integer, "review" "text", "created_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select r.rating,r.review,r.created_at from public.mentor_reviews r
  where r.mentor_id = p_mentor and public.is_verified_account()
    and (p_mentor = auth.uid() or (public.is_student_account() and public.is_approved_tutor(p_mentor)))
  order by r.created_at desc;
$$;

ALTER FUNCTION "public"."tutor_feedback"("p_mentor" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."valid_resource_link"("value" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
  select length(value) <= 2000 and value ~ '^https://[^/@[:space:]]+[.][^/@[:space:]]+([/?#][^[:space:]]*)?$';
$_$;

ALTER FUNCTION "public"."valid_resource_link"("value" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."valid_resource_tags"("value" "text"[]) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select cardinality(value) <= 8 and not exists (
    select 1 from unnest(value) tag where tag is null or char_length(trim(tag)) not between 1 and 30);
$$;

ALTER FUNCTION "public"."valid_resource_tags"("value" "text"[]) OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."content_bookmarks" (
    "user_id" "uuid" NOT NULL,
    "resource_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."content_bookmarks" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."content_publishers" (
    "user_id" "uuid" NOT NULL,
    "approved_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."content_publishers" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."content_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "resource_id" "uuid" NOT NULL,
    "reporter_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "details" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "content_reports_details_check" CHECK ((("char_length"(TRIM(BOTH FROM "details")) >= 10) AND ("char_length"(TRIM(BOTH FROM "details")) <= 1000))),
    CONSTRAINT "content_reports_reason_check" CHECK (("reason" = ANY (ARRAY['Inaccurate information'::"text", 'Inappropriate content'::"text", 'Copyright concern'::"text", 'Broken link'::"text", 'Spam'::"text", 'Other'::"text"]))),
    CONSTRAINT "content_reports_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'resolved'::"text", 'dismissed'::"text"])))
);

ALTER TABLE "public"."content_reports" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."learning_resources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author_id" "uuid" NOT NULL,
    "author_name" "text" DEFAULT ''::"text" NOT NULL,
    "title" "text" NOT NULL,
    "summary" "text" NOT NULL,
    "category" "text" NOT NULL,
    "difficulty" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "external_url" "text" DEFAULT ''::"text" NOT NULL,
    "body" "text" DEFAULT ''::"text" NOT NULL,
    "tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "moderation_hidden" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "attachment_path" "text",
    CONSTRAINT "learning_resources_body_check" CHECK (("char_length"("body") <= 20000)),
    CONSTRAINT "learning_resources_category_check" CHECK (("category" = ANY (ARRAY['Programming'::"text", 'Design'::"text", 'Business'::"text", 'Languages'::"text", 'Music'::"text", 'Lifestyle'::"text", 'Other'::"text"]))),
    CONSTRAINT "learning_resources_difficulty_check" CHECK (("difficulty" = ANY (ARRAY['Beginner'::"text", 'Intermediate'::"text", 'Advanced'::"text"]))),
    CONSTRAINT "learning_resources_kind_check" CHECK (("kind" = ANY (ARRAY['Video'::"text", 'Guide'::"text", 'Reading'::"text"]))),
    CONSTRAINT "learning_resources_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'archived'::"text"]))),
    CONSTRAINT "learning_resources_summary_check" CHECK ((("char_length"(TRIM(BOTH FROM "summary")) >= 20) AND ("char_length"(TRIM(BOTH FROM "summary")) <= 500))),
    CONSTRAINT "learning_resources_tags_check" CHECK ("public"."valid_resource_tags"("tags")),
    CONSTRAINT "learning_resources_title_check" CHECK ((("char_length"(TRIM(BOTH FROM "title")) >= 3) AND ("char_length"(TRIM(BOTH FROM "title")) <= 120))),
    CONSTRAINT "resource_link" CHECK (
CASE
    WHEN ("attachment_path" IS NOT NULL) THEN (("external_url" = ''::"text") AND ((("kind" = 'Reading'::"text") AND ("attachment_path" ~ (('^'::"text" || ("author_id")::"text") || '/[0-9a-f]{32}\.(pdf|png|jpg|jpeg)$'::"text"))) OR (("kind" = 'Video'::"text") AND ("attachment_path" ~ (('^'::"text" || ("author_id")::"text") || '/[0-9a-f]{32}\.mp4$'::"text")))))
    ELSE ((("kind" = 'Guide'::"text") AND ("char_length"(TRIM(BOTH FROM "body")) >= 20) AND (("external_url" = ''::"text") OR "public"."valid_resource_link"("external_url"))) OR (("kind" = ANY (ARRAY['Video'::"text", 'Reading'::"text"])) AND "public"."valid_resource_link"("external_url")))
END)
);

ALTER TABLE "public"."learning_resources" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."mentor_library_access" (
    "mentor_id" "uuid" NOT NULL,
    "learner_id" "uuid" NOT NULL,
    "granted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "mentor_library_access_check" CHECK (("mentor_id" <> "learner_id"))
);

ALTER TABLE "public"."mentor_library_access" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."mentor_payment_offers" (
    "mentor_id" "uuid" NOT NULL,
    "amount" integer NOT NULL,
    "currency" "text" DEFAULT 'myr'::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "mentor_payment_offers_amount_check" CHECK ((("amount" >= 200) AND ("amount" <= 1000000))),
    CONSTRAINT "mentor_payment_offers_currency_check" CHECK (("currency" = 'myr'::"text"))
);

ALTER TABLE "public"."mentor_payment_offers" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."mentor_reviews" (
    "request_id" "uuid" NOT NULL,
    "mentor_id" "uuid" NOT NULL,
    "learner_id" "uuid" NOT NULL,
    "rating" integer NOT NULL,
    "review" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "mentor_reviews_rating_check" CHECK ((("rating" >= 1) AND ("rating" <= 5))),
    CONSTRAINT "mentor_reviews_review_check" CHECK ((("char_length"(TRIM(BOTH FROM "review")) >= 10) AND ("char_length"(TRIM(BOTH FROM "review")) <= 1000)))
);

ALTER TABLE "public"."mentor_reviews" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."mentor_slots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "mentor_id" "uuid" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "schedule_generated" boolean DEFAULT false NOT NULL,
    CONSTRAINT "mentor_slots_time_range" CHECK ((("ends_at" > "starts_at") AND ("ends_at" <= ("starts_at" + '24:00:00'::interval))))
);

ALTER TABLE "public"."mentor_slots" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."mentorship_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slot_id" "uuid" NOT NULL,
    "mentor_id" "uuid" NOT NULL,
    "learner_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "payment_order_id" "uuid",
    CONSTRAINT "mentorship_requests_check" CHECK (("mentor_id" <> "learner_id")),
    CONSTRAINT "mentorship_requests_message_check" CHECK ((("char_length"(TRIM(BOTH FROM "message")) >= 10) AND ("char_length"(TRIM(BOTH FROM "message")) <= 1000))),
    CONSTRAINT "mentorship_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'declined'::"text", 'cancelled'::"text", 'completed'::"text"])))
);

ALTER TABLE "public"."mentorship_requests" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "date_of_birth" "date" NOT NULL,
    "role" "text" DEFAULT 'student'::"text" NOT NULL,
    "bio" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "profiles_bio_check" CHECK (("char_length"("bio") <= 500)),
    CONSTRAINT "profiles_date_of_birth_check" CHECK ((("date_of_birth" >= '1900-01-01'::"date") AND ("date_of_birth" <= CURRENT_DATE))),
    CONSTRAINT "profiles_full_name_check" CHECK (((("char_length"(TRIM(BOTH FROM "full_name")) >= 2) AND ("char_length"(TRIM(BOTH FROM "full_name")) <= 100)) AND ("full_name" !~ '[0-9<>[:cntrl:]]'::"text"))),
    CONSTRAINT "profiles_role_check" CHECK (("role" = ANY (ARRAY['student'::"text", 'mentor'::"text"])))
);

ALTER TABLE "public"."profiles" OWNER TO "postgres";

COMMENT ON COLUMN "public"."profiles"."role" IS 'Temporary open role selection: mentors can teach without credential review. Email confirmation is still required.';

CREATE TABLE IF NOT EXISTS "public"."tutor_profiles" (
    "user_id" "uuid" NOT NULL,
    "headline" "text" DEFAULT ''::"text" NOT NULL,
    "expertise" "text" DEFAULT ''::"text" NOT NULL,
    "experience" "text" DEFAULT ''::"text" NOT NULL,
    "credential_url" "text" DEFAULT ''::"text" NOT NULL,
    "teaching_preferences" "text" DEFAULT ''::"text" NOT NULL,
    "verification_status" "text" DEFAULT 'unsubmitted'::"text" NOT NULL,
    "review_note" "text" DEFAULT ''::"text" NOT NULL,
    "submitted_at" timestamp with time zone,
    "reviewed_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "qualification_path" "text" DEFAULT ''::"text" NOT NULL,
    "is_listed" boolean DEFAULT false NOT NULL,
    "weekly_availability" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "session_minutes" integer DEFAULT 60 NOT NULL,
    "utc_offset_minutes" integer DEFAULT 480 NOT NULL,
    CONSTRAINT "tutor_profiles_credential_url_check" CHECK ((("credential_url" = ''::"text") OR "public"."valid_resource_link"("credential_url"))),
    CONSTRAINT "tutor_profiles_experience_check" CHECK (("char_length"("experience") <= 5000)),
    CONSTRAINT "tutor_profiles_expertise_check" CHECK (("char_length"("expertise") <= 500)),
    CONSTRAINT "tutor_profiles_headline_check" CHECK (("char_length"("headline") <= 120)),
    CONSTRAINT "tutor_profiles_review_note_check" CHECK (("char_length"("review_note") <= 1000)),
    CONSTRAINT "tutor_profiles_teaching_preferences_check" CHECK (("char_length"("teaching_preferences") <= 1000)),
    CONSTRAINT "tutor_profiles_verification_status_check" CHECK (("verification_status" = ANY (ARRAY['unsubmitted'::"text", 'pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);

ALTER TABLE "public"."tutor_profiles" OWNER TO "postgres";

ALTER TABLE ONLY "public"."content_bookmarks"
    ADD CONSTRAINT "content_bookmarks_pkey" PRIMARY KEY ("user_id", "resource_id");

ALTER TABLE ONLY "public"."content_publishers"
    ADD CONSTRAINT "content_publishers_pkey" PRIMARY KEY ("user_id");

ALTER TABLE ONLY "public"."content_reports"
    ADD CONSTRAINT "content_reports_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."content_reports"
    ADD CONSTRAINT "content_reports_resource_id_reporter_id_key" UNIQUE ("resource_id", "reporter_id");

ALTER TABLE ONLY "public"."learning_resources"
    ADD CONSTRAINT "learning_resources_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."mentor_library_access"
    ADD CONSTRAINT "mentor_library_access_pkey" PRIMARY KEY ("mentor_id", "learner_id");

ALTER TABLE ONLY "public"."mentor_payment_offers"
    ADD CONSTRAINT "mentor_payment_offers_pkey" PRIMARY KEY ("mentor_id");

ALTER TABLE ONLY "public"."mentor_payments"
    ADD CONSTRAINT "mentor_payments_checkout_session_id_key" UNIQUE ("checkout_session_id");

ALTER TABLE ONLY "public"."mentor_payments"
    ADD CONSTRAINT "mentor_payments_payment_intent_id_key" UNIQUE ("payment_intent_id");

ALTER TABLE ONLY "public"."mentor_payments"
    ADD CONSTRAINT "mentor_payments_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."mentor_reviews"
    ADD CONSTRAINT "mentor_reviews_pkey" PRIMARY KEY ("request_id");

ALTER TABLE ONLY "public"."mentor_slots"
    ADD CONSTRAINT "mentor_slots_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."mentorship_requests"
    ADD CONSTRAINT "mentorship_requests_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."tutor_profiles"
    ADD CONSTRAINT "tutor_profiles_pkey" PRIMARY KEY ("user_id");

CREATE INDEX "learning_resources_attachment_path" ON "public"."learning_resources" USING "btree" ("attachment_path") WHERE ("attachment_path" IS NOT NULL);

CREATE INDEX "mentor_slot_schedule" ON "public"."mentor_slots" USING "btree" ("mentor_id", "starts_at");

CREATE UNIQUE INDEX "one_active_booking_per_student_slot" ON "public"."mentorship_requests" USING "btree" ("slot_id", "learner_id") WHERE ("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'completed'::"text"]));

CREATE UNIQUE INDEX "one_active_request_per_payment" ON "public"."mentorship_requests" USING "btree" ("payment_order_id") WHERE (("payment_order_id" IS NOT NULL) AND ("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'completed'::"text"])));

CREATE UNIQUE INDEX "one_booking_per_slot" ON "public"."mentorship_requests" USING "btree" ("slot_id") WHERE ("status" = ANY (ARRAY['accepted'::"text", 'completed'::"text"]));

CREATE UNIQUE INDEX "one_pending_material_checkout" ON "public"."mentor_payments" USING "btree" ("mentor_id", "learner_id") WHERE (("status" = 'pending'::"text") AND ("purchase_kind" = ANY (ARRAY['materials'::"text", 'legacy'::"text"])));

CREATE UNIQUE INDEX "one_pending_session_checkout" ON "public"."mentor_payments" USING "btree" ("session_slot_id", "learner_id") WHERE (("status" = 'pending'::"text") AND ("purchase_kind" = 'session'::"text"));

CREATE INDEX "resources_author" ON "public"."learning_resources" USING "btree" ("author_id", "created_at" DESC);

CREATE INDEX "resources_catalog" ON "public"."learning_resources" USING "btree" ("category", "difficulty", "kind", "created_at" DESC) WHERE (("status" = 'published'::"text") AND (NOT "moderation_hidden"));

CREATE INDEX "resources_tags" ON "public"."learning_resources" USING "gin" ("tags");

CREATE OR REPLACE TRIGGER "check_payment_before_accept" BEFORE UPDATE OF "status" ON "public"."mentorship_requests" FOR EACH ROW EXECUTE FUNCTION "public"."check_paid_request_acceptance"();

CREATE OR REPLACE TRIGGER "on_open_mentor_role" AFTER INSERT OR UPDATE OF "role" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."sync_open_mentor_role"();

CREATE OR REPLACE TRIGGER "on_profile_updated" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."touch_profile"();

CREATE OR REPLACE TRIGGER "require_qualification" BEFORE INSERT OR UPDATE ON "public"."tutor_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."require_tutor_qualification"();

CREATE OR REPLACE TRIGGER "resource_stamp" BEFORE INSERT OR UPDATE ON "public"."learning_resources" FOR EACH ROW EXECUTE FUNCTION "public"."stamp_resource"();

CREATE OR REPLACE TRIGGER "tutor_publisher_sync" AFTER INSERT OR UPDATE OF "verification_status" ON "public"."tutor_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."sync_tutor_publisher"();

ALTER TABLE ONLY "public"."content_bookmarks"
    ADD CONSTRAINT "content_bookmarks_resource_id_fkey" FOREIGN KEY ("resource_id") REFERENCES "public"."learning_resources"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."content_bookmarks"
    ADD CONSTRAINT "content_bookmarks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."content_publishers"
    ADD CONSTRAINT "content_publishers_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."content_reports"
    ADD CONSTRAINT "content_reports_reporter_id_fkey" FOREIGN KEY ("reporter_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."content_reports"
    ADD CONSTRAINT "content_reports_resource_id_fkey" FOREIGN KEY ("resource_id") REFERENCES "public"."learning_resources"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."learning_resources"
    ADD CONSTRAINT "learning_resources_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentor_library_access"
    ADD CONSTRAINT "mentor_library_access_learner_id_fkey" FOREIGN KEY ("learner_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentor_library_access"
    ADD CONSTRAINT "mentor_library_access_mentor_id_fkey" FOREIGN KEY ("mentor_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentor_payment_offers"
    ADD CONSTRAINT "mentor_payment_offers_mentor_id_fkey" FOREIGN KEY ("mentor_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentor_payments"
    ADD CONSTRAINT "mentor_payments_learner_id_fkey" FOREIGN KEY ("learner_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentor_payments"
    ADD CONSTRAINT "mentor_payments_mentor_id_fkey" FOREIGN KEY ("mentor_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentor_payments"
    ADD CONSTRAINT "mentor_payments_session_slot_id_fkey" FOREIGN KEY ("session_slot_id") REFERENCES "public"."mentor_slots"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."mentor_reviews"
    ADD CONSTRAINT "mentor_reviews_learner_id_fkey" FOREIGN KEY ("learner_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentor_reviews"
    ADD CONSTRAINT "mentor_reviews_mentor_id_fkey" FOREIGN KEY ("mentor_id") REFERENCES "public"."tutor_profiles"("user_id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentor_reviews"
    ADD CONSTRAINT "mentor_reviews_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."mentorship_requests"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentor_slots"
    ADD CONSTRAINT "mentor_slots_mentor_id_fkey" FOREIGN KEY ("mentor_id") REFERENCES "public"."tutor_profiles"("user_id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentorship_requests"
    ADD CONSTRAINT "mentorship_requests_learner_id_fkey" FOREIGN KEY ("learner_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentorship_requests"
    ADD CONSTRAINT "mentorship_requests_mentor_id_fkey" FOREIGN KEY ("mentor_id") REFERENCES "public"."tutor_profiles"("user_id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."mentorship_requests"
    ADD CONSTRAINT "mentorship_requests_payment_order_id_fkey" FOREIGN KEY ("payment_order_id") REFERENCES "public"."mentor_payments"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."mentorship_requests"
    ADD CONSTRAINT "mentorship_requests_slot_id_fkey" FOREIGN KEY ("slot_id") REFERENCES "public"."mentor_slots"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."tutor_profiles"
    ADD CONSTRAINT "tutor_profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

CREATE POLICY "Authors delete own resources" ON "public"."learning_resources" FOR DELETE TO "authenticated" USING ((("author_id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."is_verified_account"() AS "is_verified_account")));

CREATE POLICY "Mentors create own resources" ON "public"."learning_resources" FOR INSERT TO "authenticated" WITH CHECK ((("author_id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."can_author_content"() AS "can_author_content") AND (("status" <> 'published'::"text") OR ( SELECT "public"."can_publish_content"() AS "can_publish_content"))));

CREATE POLICY "Mentors edit own resources" ON "public"."learning_resources" FOR UPDATE TO "authenticated" USING ((("author_id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."can_author_content"() AS "can_author_content"))) WITH CHECK ((("author_id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."can_author_content"() AS "can_author_content") AND (("status" <> 'published'::"text") OR ( SELECT "public"."can_publish_content"() AS "can_publish_content"))));

CREATE POLICY "Read mentor package prices" ON "public"."mentor_payment_offers" FOR SELECT TO "authenticated" USING (("public"."is_verified_account"() AND (("mentor_id" = "auth"."uid"()) OR ("public"."is_student_account"() AND "public"."is_approved_tutor"("mentor_id")))));

CREATE POLICY "Read own bookmarks" ON "public"."content_bookmarks" FOR SELECT TO "authenticated" USING ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM "public"."learning_resources"
  WHERE ("learning_resources"."id" = "content_bookmarks"."resource_id")))));

CREATE POLICY "Read own or student visible mentor slots" ON "public"."mentor_slots" FOR SELECT TO "authenticated" USING (("public"."is_verified_account"() AND (("mentor_id" = "auth"."uid"()) OR ("public"."is_student_account"() AND "public"."is_approved_tutor"("mentor_id")))));

CREATE POLICY "Read own private tutor application" ON "public"."tutor_profiles" FOR SELECT TO "authenticated" USING ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) AND "public"."is_verified_account"()));

CREATE POLICY "Read own profile" ON "public"."profiles" FOR SELECT TO "authenticated" USING ((("id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."is_verified_account"() AS "is_verified_account")));

CREATE POLICY "Read own publishing approval" ON "public"."content_publishers" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Read participant requests" ON "public"."mentorship_requests" FOR SELECT TO "authenticated" USING (("public"."is_verified_account"() AND (("auth"."uid"() = "mentor_id") OR ("auth"."uid"() = "learner_id"))));

CREATE POLICY "Read participant test payments" ON "public"."mentor_payments" FOR SELECT TO "authenticated" USING (("public"."is_verified_account"() AND (("auth"."uid"() = "mentor_id") OR ("auth"."uid"() = "learner_id"))));

CREATE POLICY "Read visible or own resources" ON "public"."learning_resources" FOR SELECT TO "authenticated" USING ("public"."can_read_mentor_resource"("author_id", "status", "moderation_hidden"));

CREATE POLICY "Remove own bookmarks" ON "public"."content_bookmarks" FOR DELETE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Report other visible published resources" ON "public"."content_reports" FOR INSERT TO "authenticated" WITH CHECK ((("reporter_id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."is_verified_account"() AS "is_verified_account") AND (EXISTS ( SELECT 1
   FROM "public"."learning_resources"
  WHERE (("learning_resources"."id" = "content_reports"."resource_id") AND ("learning_resources"."author_id" <> ( SELECT "auth"."uid"() AS "uid")) AND ("learning_resources"."status" = 'published'::"text") AND (NOT "learning_resources"."moderation_hidden"))))));

CREATE POLICY "Save visible resources" ON "public"."content_bookmarks" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."is_verified_account"() AS "is_verified_account") AND (EXISTS ( SELECT 1
   FROM "public"."learning_resources"
  WHERE ("learning_resources"."id" = "content_bookmarks"."resource_id")))));

CREATE POLICY "Update own profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ((("id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."is_verified_account"() AS "is_verified_account"))) WITH CHECK ((("id" = ( SELECT "auth"."uid"() AS "uid")) AND ( SELECT "public"."is_verified_account"() AS "is_verified_account")));

ALTER TABLE "public"."content_bookmarks" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."content_publishers" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."content_reports" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."learning_resources" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."mentor_library_access" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."mentor_payment_offers" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."mentor_payments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."mentor_reviews" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."mentor_slots" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."mentorship_requests" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."tutor_profiles" ENABLE ROW LEVEL SECURITY;

ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";

GRANT USAGE ON SCHEMA "public" TO "postgres";

GRANT USAGE ON SCHEMA "public" TO "anon";

GRANT USAGE ON SCHEMA "public" TO "authenticated";

GRANT USAGE ON SCHEMA "public" TO "service_role";

REVOKE ALL ON FUNCTION "public"."available_mentor_schedule"("p_mentor" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."available_mentor_schedule"("p_mentor" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."available_mentor_schedule"("p_mentor" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."available_mentor_slots"("p_mentor" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."available_mentor_slots"("p_mentor" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."available_mentor_slots"("p_mentor" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."can_author_content"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."can_author_content"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."can_author_content"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."can_publish_content"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."can_publish_content"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."can_publish_content"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."can_read_mentor_resource"("p_author" "uuid", "p_status" "text", "p_hidden" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."can_read_mentor_resource"("p_author" "uuid", "p_status" "text", "p_hidden" boolean) TO "authenticated";

GRANT ALL ON FUNCTION "public"."can_read_mentor_resource"("p_author" "uuid", "p_status" "text", "p_hidden" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."cancel_mentor_package"("p_mentor" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."cancel_mentor_package"("p_mentor" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."cancel_mentor_package"("p_mentor" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."check_paid_request_acceptance"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."check_paid_request_acceptance"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."complete_demo_mentor_payment"("p_order" "uuid", "p_result" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."complete_demo_mentor_payment"("p_order" "uuid", "p_result" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."complete_demo_mentor_payment"("p_order" "uuid", "p_result" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."delete_mentor_slot"("p_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."delete_mentor_slot"("p_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."delete_mentor_slot"("p_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."enable_tutor_profile"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enable_tutor_profile"() TO "service_role";

GRANT ALL ON FUNCTION "public"."enable_tutor_profile"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."generate_weekly_mentor_slots"("p_mentor" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."generate_weekly_mentor_slots"("p_mentor" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."handle_new_account"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."handle_new_account"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."has_mentor_library_access"("p_mentor" "uuid", "p_learner" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."has_mentor_library_access"("p_mentor" "uuid", "p_learner" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."has_tutor_qualification"("p_path" "text", "p_user" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."has_tutor_qualification"("p_path" "text", "p_user" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."is_approved_tutor"("candidate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."is_approved_tutor"("candidate" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."is_approved_tutor"("candidate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."is_content_publisher"("candidate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."is_content_publisher"("candidate" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."is_content_publisher"("candidate" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."is_student_account"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."is_student_account"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."is_student_account"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."is_verified_account"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."is_verified_account"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."is_verified_account"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."mentor_payment_access"("p_mentor" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."mentor_payment_access"("p_mentor" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."mentor_payment_access"("p_mentor" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."my_learner_library_access"("p_learner" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."my_learner_library_access"("p_learner" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."my_learner_library_access"("p_learner" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."my_mentorship_sessions"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."my_mentorship_sessions"() TO "service_role";

GRANT ALL ON FUNCTION "public"."my_mentorship_sessions"() TO "authenticated";

GRANT ALL ON TABLE "public"."mentor_payments" TO "service_role";

GRANT SELECT ON TABLE "public"."mentor_payments" TO "authenticated";

REVOKE ALL ON FUNCTION "public"."prepare_mentor_checkout"("p_mentor" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."prepare_mentor_checkout"("p_mentor" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."prepare_mentor_checkout"("p_mentor" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."prepare_session_checkout"("p_slot" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."prepare_session_checkout"("p_slot" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."prepare_session_checkout"("p_slot" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."publish_mentor_schedule"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_availability" "jsonb", "p_session_minutes" integer, "p_utc_offset" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."publish_mentor_schedule"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_availability" "jsonb", "p_session_minutes" integer, "p_utc_offset" integer) TO "authenticated";

GRANT ALL ON FUNCTION "public"."publish_mentor_schedule"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_availability" "jsonb", "p_session_minutes" integer, "p_utc_offset" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."record_mentor_checkout"("p_order" "uuid", "p_session" "text", "p_url" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."record_mentor_checkout"("p_order" "uuid", "p_session" "text", "p_url" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."refund_mentor_payment"("p_intent" "text", "p_amount" integer, "p_currency" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."refund_mentor_payment"("p_intent" "text", "p_amount" integer, "p_currency" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."request_mentorship"("p_slot" "uuid", "p_message" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."request_mentorship"("p_slot" "uuid", "p_message" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."request_mentorship"("p_slot" "uuid", "p_message" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."request_mentorship_internal"("p_slot" "uuid", "p_message" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."request_mentorship_internal"("p_slot" "uuid", "p_message" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."require_tutor_qualification"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."require_tutor_qualification"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."respond_mentorship"("p_request" "uuid", "p_status" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."respond_mentorship"("p_request" "uuid", "p_status" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."respond_mentorship"("p_request" "uuid", "p_status" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."review_mentor"("p_request" "uuid", "p_rating" integer, "p_review" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."review_mentor"("p_request" "uuid", "p_rating" integer, "p_review" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."review_mentor"("p_request" "uuid", "p_rating" integer, "p_review" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."save_mentor_payment_offer"("p_amount" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_mentor_payment_offer"("p_amount" integer) TO "authenticated";

GRANT ALL ON FUNCTION "public"."save_mentor_payment_offer"("p_amount" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."save_mentor_slot"("p_id" "uuid", "p_start" timestamp with time zone, "p_end" timestamp with time zone) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_mentor_slot"("p_id" "uuid", "p_start" timestamp with time zone, "p_end" timestamp with time zone) TO "service_role";

GRANT ALL ON FUNCTION "public"."save_mentor_slot"("p_id" "uuid", "p_start" timestamp with time zone, "p_end" timestamp with time zone) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."save_tutor_profile"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_submit" boolean, "p_qualification_path" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_tutor_profile"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_submit" boolean, "p_qualification_path" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."save_tutor_profile"("p_headline" "text", "p_expertise" "text", "p_experience" "text", "p_credential_url" "text", "p_preferences" "text", "p_submit" boolean, "p_qualification_path" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."set_learner_library_access"("p_learner" "uuid", "p_grant" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."set_learner_library_access"("p_learner" "uuid", "p_grant" boolean) TO "authenticated";

GRANT ALL ON FUNCTION "public"."set_learner_library_access"("p_learner" "uuid", "p_grant" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."settle_mentor_payment"("p_order" "uuid", "p_session" "text", "p_intent" "text", "p_amount" integer, "p_currency" "text", "p_status" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."settle_mentor_payment"("p_order" "uuid", "p_session" "text", "p_intent" "text", "p_amount" integer, "p_currency" "text", "p_status" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."stamp_resource"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."stamp_resource"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."sync_open_mentor_role"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."sync_open_mentor_role"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."sync_tutor_publisher"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."sync_tutor_publisher"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."touch_profile"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."touch_profile"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."tutor_directory"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."tutor_directory"() TO "service_role";

GRANT ALL ON FUNCTION "public"."tutor_directory"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."tutor_feedback"("p_mentor" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."tutor_feedback"("p_mentor" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."tutor_feedback"("p_mentor" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."valid_resource_link"("value" "text") TO "anon";

GRANT ALL ON FUNCTION "public"."valid_resource_link"("value" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."valid_resource_link"("value" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."valid_resource_tags"("value" "text"[]) TO "anon";

GRANT ALL ON FUNCTION "public"."valid_resource_tags"("value" "text"[]) TO "authenticated";

GRANT ALL ON FUNCTION "public"."valid_resource_tags"("value" "text"[]) TO "service_role";

GRANT ALL ON TABLE "public"."content_bookmarks" TO "service_role";

GRANT SELECT,DELETE ON TABLE "public"."content_bookmarks" TO "authenticated";

GRANT INSERT("user_id") ON TABLE "public"."content_bookmarks" TO "authenticated";

GRANT INSERT("resource_id") ON TABLE "public"."content_bookmarks" TO "authenticated";

GRANT ALL ON TABLE "public"."content_publishers" TO "service_role";

GRANT SELECT ON TABLE "public"."content_publishers" TO "authenticated";

GRANT ALL ON TABLE "public"."content_reports" TO "service_role";

GRANT INSERT("resource_id") ON TABLE "public"."content_reports" TO "authenticated";

GRANT INSERT("reporter_id") ON TABLE "public"."content_reports" TO "authenticated";

GRANT INSERT("reason") ON TABLE "public"."content_reports" TO "authenticated";

GRANT INSERT("details") ON TABLE "public"."content_reports" TO "authenticated";

GRANT ALL ON TABLE "public"."learning_resources" TO "service_role";

GRANT SELECT,DELETE ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("author_id") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("title"),UPDATE("title") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("summary"),UPDATE("summary") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("category"),UPDATE("category") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("difficulty"),UPDATE("difficulty") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("kind"),UPDATE("kind") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("external_url"),UPDATE("external_url") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("body"),UPDATE("body") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("tags"),UPDATE("tags") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("status"),UPDATE("status") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT INSERT("attachment_path"),UPDATE("attachment_path") ON TABLE "public"."learning_resources" TO "authenticated";

GRANT ALL ON TABLE "public"."mentor_library_access" TO "service_role";

GRANT ALL ON TABLE "public"."mentor_payment_offers" TO "service_role";

GRANT SELECT ON TABLE "public"."mentor_payment_offers" TO "authenticated";

GRANT ALL ON TABLE "public"."mentor_reviews" TO "service_role";

GRANT ALL ON TABLE "public"."mentor_slots" TO "service_role";

GRANT SELECT ON TABLE "public"."mentor_slots" TO "authenticated";

GRANT ALL ON TABLE "public"."mentorship_requests" TO "service_role";

GRANT SELECT ON TABLE "public"."mentorship_requests" TO "authenticated";

GRANT ALL ON TABLE "public"."profiles" TO "service_role";

GRANT SELECT ON TABLE "public"."profiles" TO "authenticated";

GRANT UPDATE("full_name") ON TABLE "public"."profiles" TO "authenticated";

GRANT UPDATE("date_of_birth") ON TABLE "public"."profiles" TO "authenticated";

GRANT UPDATE("role") ON TABLE "public"."profiles" TO "authenticated";

GRANT UPDATE("bio") ON TABLE "public"."profiles" TO "authenticated";

GRANT ALL ON TABLE "public"."tutor_profiles" TO "service_role";

GRANT SELECT ON TABLE "public"."tutor_profiles" TO "authenticated";

-- SOURCE: SkillTrack

CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";

CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "extensions";

CREATE OR REPLACE FUNCTION "public"."assert_owned_kanban_board"("p_board_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  perform b.id from public.kanban_boards b
    join public.projects p on p.id = b.project_id
    where b.id = p_board_id and p.owner_id = auth.uid()
      and not b.is_archived and p.status <> 'archived'
    for update of b;
  if not found then raise exception 'Project board unavailable' using errcode = '42501'; end if;
end;
$$;

ALTER FUNCTION "public"."assert_owned_kanban_board"("p_board_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."backfill_resource_embeddings"("p_limit" integer DEFAULT 25) RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare source record; total integer:=0;
begin
  if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid batch size' using errcode='22023'; end if;
  for source in select s.resource_id from public.recommendation_index_sources s
    left join public.resource_embeddings e on e.resource_id=s.resource_id
    where e.resource_id is null or e.source_version<>s.source_version order by s.resource_id limit p_limit
  loop if public.enqueue_resource_embedding(source.resource_id) then total:=total+1; end if; end loop;
  return total;
end $$;

ALTER FUNCTION "public"."backfill_resource_embeddings"("p_limit" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."begin_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare t public.kanban_tasks%rowtype; s public.task_recommendation_sets%rowtype; version text; token uuid;
begin
 if p_mode is null or p_mode not in ('manual','automatic') then raise exception 'Invalid mode'; end if;
 select task.* into t from public.kanban_tasks task join public.kanban_boards b on b.id=task.board_id
 join public.projects p on p.id=b.project_id where task.id=p_task_id and p.owner_id=p_user_id
 and p.status='active' and not b.is_archived and not task.is_archived and task.status<>'completed' for update of task;
 if not found then raise exception 'Task ineligible' using errcode='42501'; end if;
 if p_mode='automatic' and not t.is_stalled then return jsonb_build_object('cached',true,'result',public.read_task_recommendations(p_task_id,p_user_id)); end if;
 insert into public.task_recommendation_sets(task_id) values(p_task_id) on conflict do nothing;
 select * into s from public.task_recommendation_sets where task_id=p_task_id for update;
 if p_mode='automatic' and s.generation_id is not null and s.stalled_at is not distinct from t.stalled_at then
  return jsonb_build_object('cached',true,'result',public.read_task_recommendations(p_task_id,p_user_id)); end if;
 if s.lease_expires_at>clock_timestamp() then raise exception 'Recommendation generation busy' using errcode='55P03'; end if;
 version:=encode(sha256(convert_to(jsonb_build_array(t.title,t.description,t.status,t.is_stalled,t.stalled_at,to_jsonb(t)->'updated_at')::text,'UTF8')),'hex');
 token:=gen_random_uuid();
 update public.task_recommendation_sets set claim_token=token,claim_version=version,claim_mode=p_mode,
 lease_expires_at=clock_timestamp()+interval '90 seconds' where task_id=p_task_id;
 return jsonb_build_object('cached',false,'token',token);
end $$;

ALTER FUNCTION "public"."begin_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."check_task_milestone_project"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare board_project uuid;
begin
  if new.milestone_id is not null then
    select project_id into board_project from public.kanban_boards where id = new.board_id for share;
    if not exists (select 1 from public.project_milestones m
        where m.id = new.milestone_id and m.project_id = board_project) then
      raise exception 'Milestone unavailable for this project' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

ALTER FUNCTION "public"."check_task_milestone_project"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."claim_resource_analysis_job"("p_resource_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare job public.resource_analysis_jobs%rowtype; moment timestamptz:=clock_timestamp();
begin
  update public.resource_analysis_jobs set status='failed',claim_token=null,lease_expires_at=null,
    error_code='lease_expired',updated_at=moment
    where status='processing' and lease_expires_at<=moment and attempt_count>=3;
  select * into job from public.resource_analysis_jobs
    where (p_resource_id is null or resource_id=p_resource_id) and attempt_count<3
      and ((status='pending' and next_attempt_at<=moment) or (status='processing' and lease_expires_at<=moment))
    order by created_at,id limit 1 for update skip locked;
  if not found then return null; end if;
  update public.resource_analysis_jobs set status='processing',attempt_count=attempt_count+1,
    claim_token=gen_random_uuid(),lease_expires_at=moment+interval '180 seconds',updated_at=moment,error_code=null
    where id=job.id returning * into job;
  return to_jsonb(job);
end $$;

ALTER FUNCTION "public"."claim_resource_analysis_job"("p_resource_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."claim_resource_embedding"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare work public.resource_embeddings%rowtype; source public.recommendation_index_sources%rowtype;
begin
  update public.resource_embeddings set status='failed',claim_token=null,lease_expires_at=null,error_code='lease_expired',updated_at=clock_timestamp()
    where status='processing' and lease_expires_at<=clock_timestamp() and attempt_count>=3;
  -- Changed or withdrawn sources never spend another model request. Backfill
  -- resets the row only for a new source version, not for repeated failed work.
  update public.resource_embeddings e set status='skipped',claim_token=null,lease_expires_at=null,error_code='source_changed',updated_at=clock_timestamp()
    where e.status in ('pending','processing') and not exists(select 1 from public.recommendation_index_sources s
      where s.resource_id=e.resource_id and s.source_version=e.source_version);
  select * into work from public.resource_embeddings
    where attempt_count<3 and ((status='pending' and next_attempt_at<=clock_timestamp())
      or (status='processing' and lease_expires_at<=clock_timestamp()))
    order by next_attempt_at,resource_id limit 1 for update skip locked;
  if not found then return null; end if;
  update public.resource_embeddings set status='processing',attempt_count=attempt_count+1,
    claim_token=gen_random_uuid(),lease_expires_at=clock_timestamp()+interval '180 seconds',updated_at=clock_timestamp()
    where resource_id=work.resource_id returning * into work;
  select * into source from public.recommendation_index_sources where resource_id=work.resource_id and source_version=work.source_version;
  return jsonb_build_object('resource_id',work.resource_id,'claim_token',work.claim_token,'source',to_jsonb(source));
end $$;

ALTER FUNCTION "public"."claim_resource_embedding"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."claim_resource_extraction"("p_lease_seconds" integer DEFAULT 900, "p_type" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_job public.resource_extractions%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then
    raise exception 'Invalid lease duration' using errcode = '22023';
  end if;

  if p_type is not null and p_type not in ('video_transcript','pdf_text') then raise exception 'Invalid extraction type'; end if;
  -- Expired final attempts become terminal rather than remaining processing.
  update public.resource_extractions set status = 'failed',
    claim_token = null, lease_expires_at = null, error_code = 'lease_expired',
    updated_at = v_now
  where status = 'processing' and lease_expires_at <= v_now
    and attempt_count >= 3;

  select * into v_job from public.resource_extractions e
  where exists (select 1 from public.learning_resources r join storage.objects o
    on o.bucket_id=e.storage_bucket and o.name=e.storage_path
    where r.id::text=e.resource_id and not r.moderation_hidden and r.status in ('draft','published')
      and ((r.kind='Video' and e.extraction_type='video_transcript') or (public.is_pdf_resource(to_jsonb(r)) and e.extraction_type='pdf_text'))
      and public.resource_analysis_storage_key(r.external_url)=o.bucket_id||'/'||o.name
      and o.id::text=e.source_file_id
      and coalesce(nullif(to_jsonb(o)->>'version',''),nullif(o.metadata->>'eTag',''),
        nullif(o.metadata->>'etag',''),extract(epoch from o.updated_at)::text)=e.source_version)
    and (p_type is null or extraction_type=p_type) and attempt_count < 3 and (
    (status = 'pending' and next_attempt_at <= v_now) or
    (status = 'processing' and lease_expires_at <= v_now))
  order by created_at, id limit 1 for update skip locked;
  if not found then return null; end if;

  update public.resource_extractions set status = 'processing',
    attempt_count = attempt_count + 1, claim_token = gen_random_uuid(),
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    error_code = null, updated_at = v_now
  where id = v_job.id returning * into v_job;

  return jsonb_build_object(
    'extraction_type', v_job.extraction_type, 'id', v_job.id, 'claim_token', v_job.claim_token,
    'resource_id', v_job.resource_id,
    'source_file_id', v_job.source_file_id,
    'source_version', v_job.source_version,
    'storage_bucket', v_job.storage_bucket,
    'storage_path', v_job.storage_path);
end;
$$;

ALTER FUNCTION "public"."claim_resource_extraction"("p_lease_seconds" integer, "p_type" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."claim_resource_image"("p_project_url" "text", "p_bucket" "text", "p_draft_resource_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $_$
declare work public.resource_extractions%rowtype; resource jsonb; mime text; etag text;
begin
 if p_project_url !~ '^https://[a-zA-Z0-9.-]+(:[0-9]+)?/?$'
   or p_project_url is null or p_bucket is null or p_bucket !~ '^[a-zA-Z0-9_-]{1,100}$'
   or p_bucket='task-attachments' then
   raise exception 'Invalid image configuration' using errcode='22023';
 end if;
 insert into public.resource_extractions(resource_id,source_file_id,source_version,storage_bucket,storage_path,extraction_type)
 select r.id::text,o.id::text,v.version,o.bucket_id,o.name,'image_description'
 from public.learning_resources r join storage.objects o
   on public.resource_analysis_storage_key(r.external_url)=o.bucket_id||'/'||o.name
 cross join lateral(select coalesce(nullif(to_jsonb(o)->>'version',''),nullif(o.metadata->>'eTag',''),
   nullif(o.metadata->>'etag',''),extract(epoch from o.updated_at)::text) version) v
 where public.is_image_resource(to_jsonb(r)) and not r.moderation_hidden
   and ((p_draft_resource_id is null and r.status='published') or (r.id=p_draft_resource_id and r.status='draft'))
   and split_part(r.external_url,'/storage/v1/object/',1)=rtrim(p_project_url,'/')
   and o.bucket_id=p_bucket and v.version is not null
   and not exists(select 1 from public.resource_extractions e where e.resource_id=r.id::text
     and e.source_file_id=o.id::text and e.source_version=v.version)
 order by r.id limit 25
 on conflict(resource_id,source_file_id,source_version) do nothing;

 update public.resource_extractions set status='failed',claim_token=null,lease_expires_at=null,
   error_code='lease_expired',updated_at=clock_timestamp()
 where extraction_type='image_description' and status='processing'
   and lease_expires_at<=clock_timestamp() and attempt_count>=3;

 select e.* into work from public.resource_extractions e
 join public.learning_resources r on r.id::text=e.resource_id
 join storage.objects o on o.bucket_id=e.storage_bucket and o.name=e.storage_path
 where e.extraction_type='image_description' and public.is_image_resource(to_jsonb(r))
   and not r.moderation_hidden
   and ((p_draft_resource_id is null and r.status='published') or (r.id=p_draft_resource_id and r.status='draft'))
   and split_part(r.external_url,'/storage/v1/object/',1)=rtrim(p_project_url,'/')
   and public.resource_analysis_storage_key(r.external_url)=o.bucket_id||'/'||o.name
   and o.bucket_id=p_bucket and o.id::text=e.source_file_id
   and coalesce(nullif(to_jsonb(o)->>'version',''),nullif(o.metadata->>'eTag',''),
     nullif(o.metadata->>'etag',''),extract(epoch from o.updated_at)::text)=e.source_version
   and e.attempt_count<3 and ((e.status='pending' and e.next_attempt_at<=clock_timestamp())
     or (e.status='processing' and e.lease_expires_at<=clock_timestamp()))
 order by e.created_at,e.id limit 1 for update of e skip locked;
 if not found then return null; end if;
 update public.resource_extractions set status='processing',attempt_count=attempt_count+1,
   claim_token=gen_random_uuid(),lease_expires_at=clock_timestamp()+interval '180 seconds',
   error_code=null,updated_at=clock_timestamp() where id=work.id returning * into work;
 select to_jsonb(r) into resource from public.learning_resources r where r.id::text=work.resource_id;
 select o.metadata->>'mimetype',coalesce(o.metadata->>'eTag',o.metadata->>'etag') into mime,etag from storage.objects o
   where o.id::text=work.source_file_id and o.bucket_id=work.storage_bucket and o.name=work.storage_path;
 return to_jsonb(work)||jsonb_build_object('resource',resource,'mime_type',mime,'object_etag',etag);
end $_$;

ALTER FUNCTION "public"."claim_resource_image"("p_project_url" "text", "p_bucket" "text", "p_draft_resource_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."claim_video_transcript"("p_lease_seconds" integer DEFAULT 900) RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
 select public.claim_resource_extraction(p_lease_seconds,'video_transcript') $$;

ALTER FUNCTION "public"."claim_video_transcript"("p_lease_seconds" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."complete_resource_analysis_job"("p_job_id" "uuid", "p_claim_token" "uuid", "p_resource" "jsonb", "p_transcript" "jsonb", "p_keywords" "text"[], "p_topic_tags" "text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare job public.resource_analysis_jobs%rowtype; resource public.learning_resources%rowtype; saved jsonb;
begin
  select * into job from public.resource_analysis_jobs where id=p_job_id for update;
  if not found or p_claim_token is null or job.claim_token is distinct from p_claim_token
    or job.status<>'processing' or job.lease_expires_at<=clock_timestamp() then
    raise exception 'Analysis claim lost' using errcode='40001';
  end if;
  select * into resource from public.learning_resources where id=job.resource_id for update;
  if not found or resource.moderation_hidden
    or not (resource.status='published' or (job.allow_draft and resource.status='draft')) then
    raise exception 'Resource ineligible' using errcode='42501';
  end if;
  if (p_resource->>'id')::uuid is distinct from job.resource_id
    or public.resource_analysis_version(p_resource,p_transcript) is distinct from job.content_version
    or (p_transcript->>'id')::uuid is distinct from job.transcript_id
    or p_transcript->>'source_file_id' is distinct from job.source_file_id
    or p_transcript->>'source_version' is distinct from job.source_version then
    raise exception 'Analysis source changed' using errcode='40001';
  end if;
  saved:=public.save_resource_analysis(resource.author_id,p_resource,p_transcript,p_keywords,p_topic_tags);
  update public.resource_analysis_jobs set status='ready',lease_expires_at=null,error_code=null,updated_at=clock_timestamp() where id=job.id;
  return saved;
end $$;

ALTER FUNCTION "public"."complete_resource_analysis_job"("p_job_id" "uuid", "p_claim_token" "uuid", "p_resource" "jsonb", "p_transcript" "jsonb", "p_keywords" "text"[], "p_topic_tags" "text"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."complete_resource_embedding"("p_resource_id" "uuid", "p_claim_token" "uuid", "p_source_version" "text", "p_embedding" "extensions"."vector", "p_keywords" "text"[], "p_topic_tags" "text"[], "p_domains" "text"[], "p_frameworks" "text"[]) RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if p_embedding is null or extensions.vector_dims(p_embedding)<>384 or extensions.vector_norm(p_embedding)<=0
    or p_keywords is null or p_topic_tags is null or p_domains is null or p_frameworks is null then
    raise exception 'Invalid embedding' using errcode='22023';
  end if;
  -- Lock order matches source editing -> analysis completion -> embedding enqueue.
  perform 1 from public.learning_resources where id=p_resource_id for share;
  update public.resource_embeddings e set embedding=p_embedding,indexed_version=p_source_version,
    keywords=p_keywords,topic_tags=p_topic_tags,domains=p_domains,frameworks=p_frameworks,
    status='ready',lease_expires_at=null,error_code=null,updated_at=clock_timestamp()
    where e.resource_id=p_resource_id and e.claim_token=p_claim_token and e.status='processing'
      and e.lease_expires_at>clock_timestamp() and e.source_version=p_source_version
      and exists(select 1 from public.recommendation_index_sources s where s.resource_id=e.resource_id and s.source_version=p_source_version);
  return found;
end $$;

ALTER FUNCTION "public"."complete_resource_embedding"("p_resource_id" "uuid", "p_claim_token" "uuid", "p_source_version" "text", "p_embedding" "extensions"."vector", "p_keywords" "text"[], "p_topic_tags" "text"[], "p_domains" "text"[], "p_frameworks" "text"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."complete_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_extracted_text" "text", "p_language" "text", "p_segments" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_job public.resource_extractions%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_extracted_text is null or length(btrim(p_extracted_text)) = 0
    or p_segments is null or jsonb_typeof(p_segments) <> 'array'
    or length(coalesce(p_language, '')) > 20 then
    raise exception 'Invalid transcript' using errcode = '22023';
  end if;
  select * into v_job from public.resource_extractions
  where id = p_extraction_id for update;
  if not found or p_claim_token is null or v_job.claim_token is distinct from p_claim_token then
    return false;
  end if;
  -- Reject a worker whose file/resource changed during download/extraction.
  perform 1 from public.learning_resources r join storage.objects o
    on o.bucket_id=v_job.storage_bucket and o.name=v_job.storage_path
  where r.id::text=v_job.resource_id and not r.moderation_hidden and r.status in ('draft','published')
    and ((r.kind='Video' and v_job.extraction_type='video_transcript')
      or (public.is_pdf_resource(to_jsonb(r)) and v_job.extraction_type='pdf_text'))
    and public.resource_analysis_storage_key(r.external_url)=o.bucket_id||'/'||o.name
    and o.id::text=v_job.source_file_id
    and coalesce(nullif(to_jsonb(o)->>'version',''),nullif(o.metadata->>'eTag',''),
      nullif(o.metadata->>'etag',''),extract(epoch from o.updated_at)::text)=v_job.source_version
    for share of r,o;
  if not found then return false; end if;
  if v_job.status = 'ready' then
    return true;
  end if;
  if v_job.status <> 'processing' or v_job.lease_expires_at <= v_now then
    return false;
  end if;

  update public.resource_extractions set status = 'ready',
    extracted_text = p_extracted_text, language = p_language, segments = p_segments,
    lease_expires_at = null, updated_at = v_now
  where id = p_extraction_id;
  return true;
end;
$$;

ALTER FUNCTION "public"."complete_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_extracted_text" "text", "p_language" "text", "p_segments" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."complete_resource_image"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_resource" "jsonb", "p_description" "text", "p_keywords" "text"[], "p_topic_tags" "text"[]) RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare work public.resource_extractions%rowtype; job_id uuid; token uuid:=gen_random_uuid();
begin
 if p_description is null or length(btrim(p_description)) not between 1 and 4000
   or p_description ~ '[[:cntrl:]]' then raise exception 'Invalid image description' using errcode='22023'; end if;
 select * into work from public.resource_extractions where id=p_extraction_id for update;
 if not found or work.extraction_type<>'image_description' or p_claim_token is null
   or work.claim_token is distinct from p_claim_token then return false; end if;
 -- On a lost-response retry, never rewrite the previously completed version.
 if work.status='ready' then return true; end if;
 if work.status<>'processing' or work.lease_expires_at<=clock_timestamp() then return false; end if;
 if p_resource->>'id' is distinct from work.resource_id then return false; end if;
 -- save_resource_analysis below locks/rechecks the current resource and Storage
 -- identity/version. An exception rolls this update and its trigger back too.
 update public.resource_extractions set status='ready',extracted_text=btrim(p_description),
   language=null,segments='[]',lease_expires_at=null,error_code=null,updated_at=clock_timestamp()
 where id=work.id returning * into work;
 job_id:=public.enqueue_resource_analysis(work.resource_id::uuid,p_resource->>'status'='draft');
 if job_id is null then raise exception 'Image source changed' using errcode='40001'; end if;
 update public.resource_analysis_jobs set status='processing',claim_token=token,
   lease_expires_at=clock_timestamp()+interval '180 seconds',attempt_count=attempt_count+1
 where id=job_id and status='pending';
 if not found then raise exception 'Image analysis claim changed' using errcode='40001'; end if;
 perform public.complete_resource_analysis_job(job_id,token,p_resource,to_jsonb(work),p_keywords,p_topic_tags);
 return true;
end $$;

ALTER FUNCTION "public"."complete_resource_image"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_resource" "jsonb", "p_description" "text", "p_keywords" "text"[], "p_topic_tags" "text"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."complete_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_token" "uuid", "p_sources" "jsonb", "p_model_id" "text", "p_text_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare t public.kanban_tasks%rowtype; s public.task_recommendation_sets%rowtype; version text; item jsonb; position integer:=0;
begin
 select task.* into t from public.kanban_tasks task join public.kanban_boards b on b.id=task.board_id
 join public.projects p on p.id=b.project_id where task.id=p_task_id and p.owner_id=p_user_id
 and p.status='active' and not b.is_archived and not task.is_archived and task.status<>'completed' for update of task for share of b,p;
 if not found then raise exception 'Task ineligible' using errcode='42501'; end if;
 select * into s from public.task_recommendation_sets where task_id=p_task_id for update;
 if s.generation_id=p_token then return public.read_task_recommendations(p_task_id,p_user_id); end if;
 version:=encode(sha256(convert_to(jsonb_build_array(t.title,t.description,t.status,t.is_stalled,t.stalled_at,to_jsonb(t)->'updated_at')::text,'UTF8')),'hex');
 if p_token is null or s.claim_token is distinct from p_token or s.lease_expires_at<=clock_timestamp()
 or s.claim_version is distinct from version or (s.claim_mode='automatic' and not t.is_stalled) then
 raise exception 'Stale recommendation generation' using errcode='40001'; end if;
 if p_sources is null or jsonb_typeof(p_sources)<>'array' or jsonb_array_length(p_sources)>3
 or p_model_id is distinct from 'gte-small' or p_text_version is distinct from 'skilltrack-v1-chunk400-mean-l2' then
 raise exception 'Invalid recommendations' using errcode='22023'; end if;
 for item in select value from jsonb_array_elements(p_sources) loop
  perform 1 from public.learning_resources where id=(item->>'resource_id')::uuid for share;
  perform 1 from public.resource_embeddings where resource_id=(item->>'resource_id')::uuid for share;
  perform 1 from public.resource_index where resource_id=(item->>'resource_id')::uuid for share;
  perform 1 from storage.objects o join public.resource_extractions e on o.id::text=e.source_file_id
   where e.resource_id=item->>'resource_id' for share of o;
  if not exists(select 1 from public.recommendation_index_sources src join public.resource_embeddings e on e.resource_id=src.resource_id
    where src.resource_id=(item->>'resource_id')::uuid and src.source_version=item->>'source_version'
    and e.status='ready' and e.indexed_version=src.source_version
    and exists(select 1 from public.recommendation_resources_for_recipient(p_user_id,array[src.resource_id]))) then
    raise exception 'Resource changed or unavailable' using errcode='40001'; end if;
 end loop;
 delete from public.task_recommendation_items where task_id=p_task_id;
 for item in select value from jsonb_array_elements(p_sources) loop
  insert into public.task_recommendation_items values(p_task_id,(item->>'resource_id')::uuid,position,item->>'source_version');position:=position+1;
 end loop;
 update public.task_recommendation_sets set generation_id=p_token,generated_at=clock_timestamp(),stalled_at=t.stalled_at,
 task_version=(select source_version from public.recommendation_load_owned_task(p_task_id,p_user_id,'manual')),
 model_id=p_model_id,text_version=p_text_version,claim_token=null,claim_version=null,claim_mode=null,lease_expires_at=null
 where task_id=p_task_id;
 return public.read_task_recommendations(p_task_id,p_user_id);
end $$;

ALTER FUNCTION "public"."complete_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_token" "uuid", "p_sources" "jsonb", "p_model_id" "text", "p_text_version" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."complete_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_transcript_text" "text", "p_language" "text", "p_segments" "jsonb") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
 select public.complete_resource_extraction(p_transcript_id,p_claim_token,p_transcript_text,p_language,p_segments) $$;

ALTER FUNCTION "public"."complete_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_transcript_text" "text", "p_language" "text", "p_segments" "jsonb") OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."project_milestones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "project_milestones_position_check" CHECK (("position" >= 0)),
    CONSTRAINT "project_milestones_title_check" CHECK ((("length"("btrim"("title")) > 0) AND ("length"("title") <= 150)))
);

ALTER TABLE "public"."project_milestones" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."create_project_milestone"("p_board_id" "uuid", "p_request_id" "text", "p_title" "text") RETURNS SETOF "public"."project_milestones"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
declare
  normalized_title text := regexp_replace(p_title, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  project uuid;
  next_position integer;
  created public.project_milestones;
  receipt public.kanban_write_requests;
begin
  if auth.uid() is null then
    raise exception 'Sign in to create milestones' using errcode = '42501';
  end if;
  if p_board_id is null or p_request_id is null
      or length(p_request_id) not between 16 and 128
      or normalized_title is null or length(normalized_title) not between 1 and 150 then
    raise exception 'Invalid milestone request' using errcode = '22023';
  end if;

  -- Same lock order and operation-ID namespace as the generated-task RPCs.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_request_id, 0));
  perform public.assert_owned_kanban_board(p_board_id);
  select b.project_id into project from public.kanban_boards b where b.id = p_board_id;
  -- This also serializes manual/AI milestone positions across a project's boards.
  perform p.id from public.projects p
    where p.id = project and p.owner_id = auth.uid() and p.status <> 'archived'
    for update;
  if not found then
    raise exception 'Project board unavailable' using errcode = '42501';
  end if;

  select * into receipt from public.kanban_write_requests
    where user_id = auth.uid() and request_id = p_request_id;
  if found then
    if receipt.board_id <> p_board_id
        or receipt.payload->>'format' is distinct from 'manual-milestone-v1'
        or receipt.payload->>'title' is distinct from normalized_title then
      raise exception 'Request identifier already used for another payload' using errcode = '22023';
    end if;
    select * into created from public.project_milestones m
      where m.id = (receipt.payload->>'milestone_id')::uuid and m.project_id = project;
    if not found then
      raise exception 'Saved milestone unavailable; refresh the board' using errcode = '22023';
    end if;
    return next created;
    return;
  end if;

  select coalesce(max(position), -1) + 1 into next_position
    from public.project_milestones where project_id = project;
  insert into public.project_milestones(project_id, title, position)
    values(project, normalized_title, next_position) returning * into created;
  insert into public.kanban_write_requests(user_id, request_id, board_id, payload, saved_count)
    values(auth.uid(), p_request_id, p_board_id,
      jsonb_build_object('format', 'manual-milestone-v1', 'title', normalized_title,
        'milestone_id', created.id), 1);
  return next created;
end;
$_$;

ALTER FUNCTION "public"."create_project_milestone"("p_board_id" "uuid", "p_request_id" "text", "p_title" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."delete_kanban_task_attachment"("p_attachment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  attachment public.task_attachments;
  board uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in to delete attachments' using errcode = '42501';
  end if;
  select a.* into attachment from public.task_attachments a where a.id = p_attachment_id;
  if not found then return; end if;
  select t.board_id into board from public.kanban_tasks t where t.id = attachment.task_id;
  perform public.assert_owned_kanban_board(board);
  perform t.id from public.kanban_tasks t where t.id = attachment.task_id
    and not coalesce(t.is_archived, false) for update;
  if not found then raise exception 'Task unavailable' using errcode = '42501'; end if;
  delete from public.task_attachments where id = p_attachment_id returning * into attachment;
  if found then
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      values (attachment.task_id, 'attachment_removed', jsonb_build_object('file_name', attachment.file_name), '{}'::jsonb);
  end if;
end;
$$;

ALTER FUNCTION "public"."delete_kanban_task_attachment"("p_attachment_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."delete_owned_task_tag"("p_tag_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
declare
  caller uuid := auth.uid();
  tag_owner uuid;
begin
  if caller is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_tag_id is null then
    raise exception 'Tag ID required' using errcode = '22004';
  end if;
  -- Lock the parent before touching links; serialize duplicate deletions and
  -- conflict with FK checks for concurrent link inserts.
  select owner_id into tag_owner from public.task_tags
    where id = p_tag_id for update;
  if not found then
    return; -- Includes retry after a committed deletion with a lost response.
  end if;
  if tag_owner is distinct from caller then
    raise exception 'Tag access denied' using errcode = '42501';
  end if;
  delete from public.task_tag_links where tag_id = p_tag_id;
  delete from public.task_tags where id = p_tag_id;
end;
$$;

ALTER FUNCTION "public"."delete_owned_task_tag"("p_tag_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."delete_task_checklist_item"("p_item_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_task_id uuid; v_board_id uuid;
begin
  select c.task_id, t.board_id into v_task_id, v_board_id
    from public.task_checklist_items c join public.kanban_tasks t on t.id = c.task_id
    where c.id = p_item_id;
  perform public.assert_owned_kanban_board(v_board_id);
  delete from public.task_checklist_items where id = p_item_id;
  insert into public.task_activity_logs (task_id, action, old_values, new_values)
    values (v_task_id, 'checklist_updated', '{}'::jsonb, '{"change":"removed"}'::jsonb);
end;
$$;

ALTER FUNCTION "public"."delete_task_checklist_item"("p_item_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enqueue_app_notification"("p_notification" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  insert into public.notifications (
    user_id, type, context_type, project_id, board_id, task_id,
    title, message, action_data, unique_key)
  values (
    (p_notification->>'user_id')::uuid,
    p_notification->>'type', p_notification->>'context_type',
    (p_notification->>'project_id')::uuid,
    (p_notification->>'board_id')::uuid,
    (p_notification->>'task_id')::uuid,
    p_notification->>'title', p_notification->>'message',
    coalesce(p_notification->'action_data', '{}'::jsonb),
    p_notification->>'unique_key')
  on conflict (user_id, unique_key) where unique_key is not null do nothing;
  return found;
end;
$$;

ALTER FUNCTION "public"."enqueue_app_notification"("p_notification" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enqueue_discovered_extraction"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text", "p_allow_draft" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare resource public.learning_resources%rowtype; object storage.objects%rowtype; version text; result uuid; kind text;
begin
 select * into resource from public.learning_resources r where r.id=p_resource_id
  and r.external_url=p_external_url and not r.moderation_hidden
  and (r.status='published' or (p_allow_draft and r.status='draft')) for share;
 if not found or public.resource_analysis_storage_key(p_external_url) is distinct from p_storage_bucket||'/'||p_storage_path then return null; end if;
 if resource.kind='Video' then kind:='video_transcript';
 elsif public.is_pdf_resource(to_jsonb(resource)) and p_storage_bucket='marketplace-documents' then kind:='pdf_text';
 else return null; end if;
 select * into object from storage.objects o where o.bucket_id=p_storage_bucket and o.name=p_storage_path for share;
 if not found then return null; end if;
 version:=coalesce(nullif(to_jsonb(object)->>'version',''),nullif(object.metadata->>'eTag',''),nullif(object.metadata->>'etag',''),extract(epoch from object.updated_at)::text);
 if version is null then return null; end if;
 insert into public.resource_extractions(resource_id,source_file_id,source_version,storage_bucket,storage_path,extraction_type)
 values(p_resource_id::text,object.id::text,version,p_storage_bucket,p_storage_path,kind)
 on conflict(resource_id,source_file_id,source_version) do nothing returning id into result;
 if result is null then select id into result from public.resource_extractions where resource_id=p_resource_id::text and source_file_id=object.id::text and source_version=version; end if;
 return result;
end $$;

ALTER FUNCTION "public"."enqueue_discovered_extraction"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text", "p_allow_draft" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enqueue_discovered_video"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text", "p_allow_draft" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'storage', 'pg_temp'
    AS $$
declare
  v_object storage.objects%rowtype;
  v_version text;
  v_transcript_id uuid;
begin
  -- Recheck eligibility and the exact reference after candidate selection.
  -- The trusted worker validates the URL's project, bucket and stable endpoint.
  perform 1 from public.learning_resources r
    where r.id = p_resource_id and r.kind = 'Video'
      and r.moderation_hidden = false and r.external_url = p_external_url
      and (r.status = 'published' or (p_allow_draft and r.status = 'draft'))
    for share;
  if not found then return null; end if;

  select * into v_object from storage.objects o
    where o.bucket_id = p_storage_bucket and o.name = p_storage_path for share;
  if not found then return null; end if;
  -- Storage object identity is the fallback file ID. Prefer Storage's upload
  -- version; older Storage installations can use etag or last modification.
  v_version := coalesce(nullif(to_jsonb(v_object)->>'version', ''),
                        nullif(v_object.metadata->>'eTag', ''),
                        nullif(v_object.metadata->>'etag', ''),
                        extract(epoch from v_object.updated_at)::text);
  if v_version is null then return null; end if;

  if exists(select 1 from public.video_transcripts t
      where t.resource_id = p_resource_id::text
        and t.source_file_id = v_object.id::text and t.source_version = v_version
        and t.status = 'ready') then
    return null;
  end if;
  select j.id into v_transcript_id from public.video_transcripts j
    where j.resource_id = p_resource_id::text
      and j.source_file_id = v_object.id::text and j.source_version = v_version;
  if found then return v_transcript_id; end if;
  return public.enqueue_video_transcription(
    p_resource_id::text, v_object.id::text, v_version,
    p_storage_bucket, p_storage_path);
end;
$$;

ALTER FUNCTION "public"."enqueue_discovered_video"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text", "p_allow_draft" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enqueue_ready_resource_analysis"("p_resource_id" "uuid" DEFAULT NULL::"uuid", "p_allow_draft" boolean DEFAULT false, "p_limit" integer DEFAULT 25) RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare source record; queued integer:=0;
begin
  if p_limit is null or p_limit not between 1 and 100 or (p_allow_draft and p_resource_id is null) then
    raise exception 'Invalid analysis backfill request' using errcode='22023';
  end if;
  for source in select c.resource_id from public.resource_analysis_candidates(p_resource_id,p_allow_draft) c
    left join public.resource_analysis_jobs j on j.resource_id=c.resource_id and j.content_version=c.content_version
    where j.id is null or (j.status='ready' and exists(select 1 from public.resource_analysis_jobs newer
      where newer.resource_id=j.resource_id and newer.status='ready' and newer.content_version<>j.content_version and newer.updated_at>j.updated_at))
    order by c.resource_id limit p_limit
  loop
    if public.enqueue_resource_analysis(source.resource_id,p_allow_draft) is not null then queued:=queued+1; end if;
  end loop;
  return queued;
end $$;

ALTER FUNCTION "public"."enqueue_ready_resource_analysis"("p_resource_id" "uuid", "p_allow_draft" boolean, "p_limit" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enqueue_resource_analysis"("p_resource_id" "uuid", "p_allow_draft" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare source record; result uuid;
begin
  select * into source from public.resource_analysis_candidates(p_resource_id,p_allow_draft);
  if not found then return null; end if;
  insert into public.resource_analysis_jobs(resource_id,transcript_id,source_file_id,source_version,content_version,allow_draft)
    values(source.resource_id,source.transcript_id,source.source_file_id,source.source_version,source.content_version,p_allow_draft)
  on conflict(resource_id,content_version) do nothing returning id into result;
  if result is null then
    -- A -> B -> A needs another analysis only if B has actually replaced the
    -- saved index. Do not reset failed jobs or ordinary duplicate completions.
    update public.resource_analysis_jobs j set status='pending',attempt_count=0,
      claim_token=null,lease_expires_at=null,next_attempt_at=clock_timestamp(),
      error_code=null,updated_at=clock_timestamp(),allow_draft=p_allow_draft
    where j.resource_id=source.resource_id and j.content_version=source.content_version and j.status='ready'
      and exists(select 1 from public.resource_analysis_jobs newer where newer.resource_id=j.resource_id
        and newer.status='ready' and newer.content_version<>j.content_version and newer.updated_at>j.updated_at)
    returning id into result;
    if result is null then
      select id into result from public.resource_analysis_jobs
        where resource_id=source.resource_id and content_version=source.content_version;
    end if;
  end if;
  return result;
end $$;

ALTER FUNCTION "public"."enqueue_resource_analysis"("p_resource_id" "uuid", "p_allow_draft" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enqueue_resource_embedding"("p_resource_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare version text;
begin
  select source_version into version from public.recommendation_index_sources where resource_id=p_resource_id;
  if not found then return false; end if;
  insert into public.resource_embeddings(resource_id,source_version) values(p_resource_id,version)
  on conflict(resource_id) do update set source_version=excluded.source_version,
    status='pending',attempt_count=0,claim_token=null,lease_expires_at=null,error_code=null,
    next_attempt_at=clock_timestamp(),updated_at=clock_timestamp()
    where resource_embeddings.source_version<>excluded.source_version;
  return found;
end $$;

ALTER FUNCTION "public"."enqueue_resource_embedding"("p_resource_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enqueue_stalled_period_alert"("p_task_id" "uuid", "p_user_id" "uuid", "p_stalled_at" timestamp with time zone, "p_resource_id" "uuid" DEFAULT NULL::"uuid", "p_resource_version" "text" DEFAULT NULL::"text", "p_task_version" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    SET "TimeZone" TO 'UTC'
    AS $$
declare ctx record; prefs record; resource record; category text; episode text;
  use_recommendation boolean := false; payload jsonb;
begin
  select t.*,b.project_id,p.owner_id into ctx from public.kanban_tasks t
    join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
    where t.id=p_task_id and p.owner_id=p_user_id and p.status='active'
      and not b.is_archived and not t.is_archived and t.status<>'completed'
      and t.is_stalled and t.stalled_at=p_stalled_at
    for update of t for share of b,p;
  if not found or public.stalled_period_alert_state(p_task_id,p_user_id,p_stalled_at)<>'eligible' then return false; end if;
  select stalled_task_enabled,recommendation_enabled into prefs
    from public.notification_preferences where user_id=p_user_id for share;
  if p_resource_id is not null and coalesce(prefs.recommendation_enabled,true) then
    -- Locks prevent a concurrent hide/edit from racing the final check/insert.
    perform 1 from public.learning_resources where id=p_resource_id for share;
    perform 1 from public.resource_index where resource_id=p_resource_id for share;
    perform 1 from public.resource_embeddings where resource_id=p_resource_id for share;
    perform 1 from storage.objects o join public.video_transcripts t
      on o.id::text=t.source_file_id where t.resource_id=p_resource_id::text for share of o;
    select s.* into resource from public.recommendation_index_sources s
      join public.resource_embeddings e on e.resource_id=s.resource_id
      where s.resource_id=p_resource_id and s.source_version=p_resource_version
        and e.status='ready' and e.indexed_version=s.source_version
        and exists(select 1 from public.recommendation_resources_for_recipient(p_user_id,array[p_resource_id]))
        and exists(select 1 from public.recommendation_load_owned_task(p_task_id,p_user_id) t
          where t.is_stalled and t.source_version=p_task_version);
    use_recommendation := found;
  end if;
  if not use_recommendation and not coalesce(prefs.stalled_task_enabled,true) then return false; end if;
  category := case when use_recommendation then 'LEARNING_RESOURCE_RECOMMENDATION' else 'STALLED_TASK' end;
  episode := to_char(p_stalled_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  payload := jsonb_build_object('user_id',p_user_id,'type',category,
    'context_type',case when use_recommendation then 'RECOMMENDATION' else 'TASK' end,
    'project_id',ctx.project_id,'board_id',ctx.board_id,'task_id',p_task_id,
    'title',case when use_recommendation then 'Resources to help you get unstuck' else 'Task may be stalled' end,
    'message',case when use_recommendation then format('“%s” may help with “%s”.',left(resource.title,150),left(ctx.title,150))
      else format('“%s” has a stagnation score of %s/100.',ctx.title,ctx.stagnation_score) end,
    'unique_key',lower(category)||':'||p_task_id::text||':'||episode,
    'action_data',case when use_recommendation then jsonb_build_object('section','learning_resources','resource_id',p_resource_id,'stalled_at',episode)
      else jsonb_build_object('stalled_at',episode) end);
  return public.enqueue_app_notification(payload);
end $$;

ALTER FUNCTION "public"."enqueue_stalled_period_alert"("p_task_id" "uuid", "p_user_id" "uuid", "p_stalled_at" timestamp with time zone, "p_resource_id" "uuid", "p_resource_version" "text", "p_task_version" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enqueue_video_analysis"("p_transcript_id" "uuid", "p_allow_draft" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare resource_uuid uuid;
begin
  select r.id into resource_uuid from public.video_transcripts t
    join public.learning_resources r on r.id::text=t.resource_id
    join lateral public.resource_analysis_candidates(r.id,p_allow_draft) candidate on candidate.transcript_id=t.id
    where t.id=p_transcript_id;
  if resource_uuid is null then return null; end if;
  return public.enqueue_resource_analysis(resource_uuid,p_allow_draft);
end $$;

ALTER FUNCTION "public"."enqueue_video_analysis"("p_transcript_id" "uuid", "p_allow_draft" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."enqueue_video_transcription"("p_resource_id" "text", "p_source_file_id" "text", "p_source_version" "text", "p_storage_bucket" "text", "p_storage_path" "text") RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'storage', 'pg_temp'
    AS $$
declare v_id uuid; v_existing public.resource_extractions%rowtype;
begin
  if p_resource_id is null or length(btrim(p_resource_id)) not between 1 and 256
    or p_source_file_id is null or length(btrim(p_source_file_id)) not between 1 and 256
    or p_source_version is null or length(btrim(p_source_version)) not between 1 and 256
    or p_storage_bucket is null or length(btrim(p_storage_bucket)) not between 1 and 100
    or p_storage_bucket like '%/%'
    or p_storage_path is null or length(btrim(p_storage_path)) not between 1 and 1024
    or exists (select 1 from unnest(string_to_array(p_storage_path, '/')) as parts(segment)
      where segment in ('', '.', '..')) then
    raise exception 'Invalid transcription source' using errcode = '22023';
  end if;

  -- The confirmed resource PK is UUID. Keep legacy stored text IDs intact.
  -- Backend callers must verify the resource/file association before enqueue.
  perform 1 from public.learning_resources r
    where r.id::text = p_resource_id and r.kind = 'Video'
      and r.moderation_hidden = false and r.status in ('draft','published') for share;
  if not found then
    raise exception 'Eligible video resource not found' using errcode = 'P0002';
  end if;
  perform 1 from storage.objects o
    where o.bucket_id = p_storage_bucket and o.name = p_storage_path for share;
  if not found then
    raise exception 'Video Storage object not found' using errcode = 'P0002';
  end if;

  insert into public.resource_extractions
    (resource_id, source_file_id, source_version, storage_bucket, storage_path)
  values (p_resource_id, p_source_file_id, p_source_version,
          p_storage_bucket, p_storage_path)
  on conflict (resource_id, source_file_id, source_version) do nothing
  returning id into v_id;
  if v_id is not null then return v_id; end if;

  select * into v_existing from public.resource_extractions
  where resource_id = p_resource_id and source_file_id = p_source_file_id
    and source_version = p_source_version;
  if v_existing.storage_bucket is distinct from p_storage_bucket
    or v_existing.storage_path is distinct from p_storage_path then
    raise exception 'Source version already enqueued for a different object'
      using errcode = '23505';
  end if;
  return v_existing.id;
end;
$$;

ALTER FUNCTION "public"."enqueue_video_transcription"("p_resource_id" "text", "p_source_file_id" "text", "p_source_version" "text", "p_storage_bucket" "text", "p_storage_path" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."fail_resource_analysis_job"("p_job_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text", "p_skip" boolean DEFAULT false, "p_retry_after_seconds" integer DEFAULT 60) RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if p_error_code is null or p_error_code not in
    ('source_replaced','resource_ineligible','analysis_failed','gemini_rate_limited','gemini_unavailable',
     'gemini_response_invalid','analysis_timeout','resource_changed','resource_backend_unavailable',
     'video_transcript_not_ready','video_storage_reference_unsupported','resource_content_too_large','resource_content_empty')
    or p_retry_after_seconds is null or p_retry_after_seconds not between 1 and 86400 then
    raise exception 'Invalid analysis failure' using errcode='22023';
  end if;
  update public.resource_analysis_jobs set
    status=case when p_skip then 'skipped' when attempt_count>=3 then 'failed' else 'pending' end,
    claim_token=null,lease_expires_at=null,error_code=p_error_code,updated_at=clock_timestamp(),
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(p_retry_after_seconds,60*attempt_count))
    where id=p_job_id and claim_token=p_claim_token and status='processing' and lease_expires_at>clock_timestamp();
  return found;
end $$;

ALTER FUNCTION "public"."fail_resource_analysis_job"("p_job_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text", "p_skip" boolean, "p_retry_after_seconds" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."fail_resource_embedding"("p_resource_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if p_error_code not in ('embedding_unavailable','source_changed') or p_error_code is null then
    raise exception 'Invalid failure' using errcode='22023'; end if;
  update public.resource_embeddings set status=case when p_error_code='source_changed' then 'skipped' when attempt_count>=3 then 'failed' else 'pending' end,
    claim_token=null,lease_expires_at=null,error_code=p_error_code,next_attempt_at=clock_timestamp()+make_interval(secs=>60*attempt_count),updated_at=clock_timestamp()
    where resource_id=p_resource_id and claim_token=p_claim_token and status='processing' and lease_expires_at>clock_timestamp();
  return found;
end $$;

ALTER FUNCTION "public"."fail_resource_embedding"("p_resource_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."fail_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_job public.resource_extractions%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_error_code is null or p_error_code not in
    ('download_failed', 'transcription_failed', 'save_failed', 'pdf_invalid', 'pdf_encrypted', 'pdf_empty', 'pdf_ocr_failed', 'pdf_extraction_failed', 'source_replaced') then
    raise exception 'Invalid failure code' using errcode = '22023';
  end if;
  select * into v_job from public.resource_extractions
  where id = p_extraction_id for update;
  if not found or v_job.status <> 'processing'
    or v_job.claim_token is distinct from p_claim_token
    or v_job.lease_expires_at <= v_now then
    return false;
  end if;
  update public.resource_extractions set
    status = case when attempt_count >= 3 then 'failed' else 'pending' end,
    claim_token = null, lease_expires_at = null,
    next_attempt_at = v_now + make_interval(mins => least(30, attempt_count * 2)),
    error_code = p_error_code, updated_at = v_now
  where id = p_extraction_id;
  return true;
end;
$$;

ALTER FUNCTION "public"."fail_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."fail_resource_image"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text", "p_retry_after_seconds" integer DEFAULT 60) RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
 if p_error_code is null or p_error_code not in ('image_invalid','image_mime_mismatch',
   'image_unsupported','image_too_large','image_download_failed','image_configuration_invalid',
   'source_replaced','resource_changed','gemini_response_invalid','gemini_rate_limited','gemini_unavailable',
   'gemini_not_configured','analysis_timeout','analysis_failed') then
   raise exception 'Invalid image failure code' using errcode='22023';
 end if;
 update public.resource_extractions set
   status=case when attempt_count>=3 or p_error_code in ('image_invalid','image_mime_mismatch',
     'image_unsupported','image_too_large','image_configuration_invalid','source_replaced') then 'failed' else 'pending' end,
   claim_token=null,lease_expires_at=null,error_code=p_error_code,
   next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(60,least(86400,coalesce(p_retry_after_seconds,60)),attempt_count*120)),
   updated_at=clock_timestamp()
 where id=p_extraction_id and extraction_type='image_description' and status='processing'
   and claim_token=p_claim_token and lease_expires_at>clock_timestamp();
 return found;
end $$;

ALTER FUNCTION "public"."fail_resource_image"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text", "p_retry_after_seconds" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."fail_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_token" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
 if not exists(select 1 from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
 where t.id=p_task_id and p.owner_id=p_user_id) then raise exception 'Task access denied' using errcode='42501'; end if;
 update public.task_recommendation_sets set claim_token=null,claim_version=null,claim_mode=null,lease_expires_at=null
 where task_id=p_task_id and claim_token=p_token;
end $$;

ALTER FUNCTION "public"."fail_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_token" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."fail_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
 select public.fail_resource_extraction(p_transcript_id,p_claim_token,p_error_code) $$;

ALTER FUNCTION "public"."fail_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."invoke_generate_notifications"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare project_url text;
declare cron_secret text;
begin
  select decrypted_secret into project_url
  from vault.decrypted_secrets where name = 'notification_project_url';
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets where name = 'notification_cron_secret';
  if nullif(project_url, '') is null or nullif(cron_secret, '') is null then
    raise warning 'Notification cron secrets are not configured';
    return;
  end if;
  perform net.http_post(
    url := rtrim(project_url, '/') || '/functions/v1/generate-notifications',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-notification-cron-secret', cron_secret),
    body := '{}'::jsonb
  );
end;
$$;

ALTER FUNCTION "public"."invoke_generate_notifications"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."invoke_project_notification_generator"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare project_url text;
declare cron_secret text;
begin
  select decrypted_secret into project_url
  from vault.decrypted_secrets where name = 'project_notification_url';
  select decrypted_secret into cron_secret
  from vault.decrypted_secrets where name = 'project_notification_cron_secret';
  if nullif(project_url, '') is null or nullif(cron_secret, '') is null then
    raise warning 'Notification cron secrets are not configured';
    return;
  end if;
  perform net.http_post(
    url := rtrim(project_url, '/') || '/functions/v1/project-notification-generator',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-notification-cron-secret', cron_secret),
    body := '{}'::jsonb, timeout_milliseconds := 75000
  );
end;
$$;

ALTER FUNCTION "public"."invoke_project_notification_generator"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."invoke_resource_analysis_queue"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare project_url text; shared_secret text;
begin
  select decrypted_secret into project_url from vault.decrypted_secrets where name='resource_analysis_url';
  select decrypted_secret into shared_secret from vault.decrypted_secrets where name='resource_analysis_cron_secret';
  if nullif(project_url,'') is null or length(coalesce(shared_secret,''))<32 then return; end if;
  perform net.http_post(
    url:=rtrim(project_url,'/')||'/functions/v1/resource-analysis-queue',
    headers:=jsonb_build_object('Content-Type','application/json','x-resource-analysis-secret',shared_secret),
    body:='{}'::jsonb,timeout_milliseconds:=75000);
end $$;

ALTER FUNCTION "public"."invoke_resource_analysis_queue"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."is_image_resource"("p_resource" "jsonb") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $_$
 select coalesce(p_resource->>'kind'='Reading' and (
   public.resource_analysis_storage_key(p_resource->>'external_url') ~* '\.(png|jpe?g|gif|webp|bmp|svg|heic)$'
   or exists(select 1 from storage.objects o
     where o.bucket_id||'/'||o.name=public.resource_analysis_storage_key(p_resource->>'external_url')
       and lower(o.metadata->>'mimetype') like 'image/%')),false)
$_$;

ALTER FUNCTION "public"."is_image_resource"("p_resource" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."is_pdf_resource"("p_resource" "jsonb") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $_$
 select coalesce(p_resource->>'kind'='Reading' and not public.is_image_resource(p_resource)
   and public.resource_analysis_storage_key(p_resource->>'external_url') ~* '^marketplace-documents/.+\.pdf$',false)
$_$;

ALTER FUNCTION "public"."is_pdf_resource"("p_resource" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."keep_board_milestone_project"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if new.project_id is distinct from old.project_id and exists (
    select 1 from public.kanban_tasks t where t.board_id = old.id and t.milestone_id is not null
  ) then
    raise exception 'A board with milestone tasks cannot be transferred' using errcode = '23514';
  end if;
  return new;
end;
$$;

ALTER FUNCTION "public"."keep_board_milestone_project"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."keep_milestone_project"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if new.project_id is distinct from old.project_id then
    raise exception 'A milestone cannot be transferred to another project' using errcode = '23514';
  end if;
  return new;
end;
$$;

ALTER FUNCTION "public"."keep_milestone_project"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."match_resource_embeddings"("p_task_id" "uuid", "p_user_id" "uuid", "p_task_version" "text", "p_visible_ids" "uuid"[], "p_embedding" "extensions"."vector", "p_model_id" "text", "p_text_version" "text", "p_keywords" "text"[], "p_topic_tags" "text"[], "p_frameworks" "text"[], "p_domains" "text"[], "p_min_similarity" double precision DEFAULT 0.65, "p_min_score" double precision DEFAULT 0.5, "p_semantic_weight" double precision DEFAULT 0.75, "p_keyword_weight" double precision DEFAULT 0.7) RETURNS TABLE("resource_id" "uuid", "similarity" double precision, "score" double precision, "lexical_score" double precision, "source_version" "text", "title" "text", "summary" "text", "resource_type" "text", "resource_updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select * from public.match_resource_embeddings(p_task_id,p_user_id,'automatic',p_task_version,p_visible_ids,
    p_embedding,p_model_id,p_text_version,p_keywords,p_topic_tags,p_frameworks,p_domains,
    p_min_similarity,p_min_score,p_semantic_weight,p_keyword_weight);
$$;

ALTER FUNCTION "public"."match_resource_embeddings"("p_task_id" "uuid", "p_user_id" "uuid", "p_task_version" "text", "p_visible_ids" "uuid"[], "p_embedding" "extensions"."vector", "p_model_id" "text", "p_text_version" "text", "p_keywords" "text"[], "p_topic_tags" "text"[], "p_frameworks" "text"[], "p_domains" "text"[], "p_min_similarity" double precision, "p_min_score" double precision, "p_semantic_weight" double precision, "p_keyword_weight" double precision) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."match_resource_embeddings"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text", "p_task_version" "text", "p_visible_ids" "uuid"[], "p_embedding" "extensions"."vector", "p_model_id" "text", "p_text_version" "text", "p_keywords" "text"[], "p_topic_tags" "text"[], "p_frameworks" "text"[], "p_domains" "text"[], "p_min_similarity" double precision DEFAULT 0.65, "p_min_score" double precision DEFAULT 0.5, "p_semantic_weight" double precision DEFAULT 0.75, "p_keyword_weight" double precision DEFAULT 0.7) RETURNS TABLE("resource_id" "uuid", "similarity" double precision, "score" double precision, "lexical_score" double precision, "source_version" "text", "title" "text", "summary" "text", "resource_type" "text", "resource_updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
begin
  if p_embedding is null or extensions.vector_dims(p_embedding) <> 384
    or extensions.vector_norm(p_embedding) <= 0 or p_model_id is distinct from 'gte-small'
    or p_text_version is distinct from 'skilltrack-v1-chunk400-mean-l2'
    or p_keywords is null or p_topic_tags is null or p_frameworks is null or p_domains is null
    or p_min_similarity is null or p_min_score is null or p_semantic_weight is null or p_keyword_weight is null
    or not (p_min_similarity between 0 and 1 and p_min_score between 0 and 1
      and p_semantic_weight between 0 and 1 and p_keyword_weight between 0 and 1) then
    raise exception 'Invalid search configuration or vector' using errcode='22023';
  end if;
  if not exists(select 1 from public.recommendation_load_owned_task(p_task_id,p_user_id,p_mode) t
    where (p_mode='manual' or t.is_stalled) and t.source_version=p_task_version) then return; end if;
  return query
  -- Exact search over the eligible set is deliberate at the initial marketplace
  -- scale. ANN oversampling followed by filtering could starve the top three.
  with eligible as materialized (
    select e.*,r.title,r.summary,r.resource_type,r.resource_updated_at from public.resource_embeddings e join public.recommendation_index_sources r
      on r.resource_id=e.resource_id and r.source_version=e.indexed_version
    where e.status='ready' and e.resource_id=any(p_visible_ids) and e.model_id=p_model_id and e.text_version=p_text_version
      and (cardinality(p_domains)=0 or cardinality(e.domains)=0 or e.domains && p_domains)
      and (cardinality(p_frameworks)=0 or cardinality(e.frameworks)=0 or e.frameworks && p_frameworks)
  ), measured as (
    select e.resource_id,e.source_version,e.title,e.summary,e.resource_type,e.resource_updated_at,e.frameworks,
      greatest(-1.0,least(1.0,1-(e.embedding operator(extensions.<=>) p_embedding)))::double precision sim,
      (p_keyword_weight*public.recommendation_jaccard(p_keywords,e.keywords)+
        (1-p_keyword_weight)*public.recommendation_jaccard(p_topic_tags,e.topic_tags)) lex
    from eligible e
  ), ranked as (
    select m.*,p_semantic_weight*m.sim+(1-p_semantic_weight)*m.lex rank_score from measured m
    where m.sim>=p_min_similarity and
      ((cardinality(p_frameworks)>0 and cardinality(m.frameworks)>0) or m.lex>0)
  )
  select r.resource_id,r.sim,r.rank_score,r.lex,r.source_version,r.title,r.summary,r.resource_type,r.resource_updated_at from ranked r
  where r.rank_score>=p_min_score order by r.rank_score desc,r.sim desc,r.resource_id limit 3;
end $$;

ALTER FUNCTION "public"."match_resource_embeddings"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text", "p_task_version" "text", "p_visible_ids" "uuid"[], "p_embedding" "extensions"."vector", "p_model_id" "text", "p_text_version" "text", "p_keywords" "text"[], "p_topic_tags" "text"[], "p_frameworks" "text"[], "p_domains" "text"[], "p_min_similarity" double precision, "p_min_score" double precision, "p_semantic_weight" double precision, "p_keyword_weight" double precision) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."notification_preferences_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;

ALTER FUNCTION "public"."notification_preferences_timestamp"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."notification_project_candidates"("p_offset" integer, "p_limit" integer) RETURNS TABLE("project_id" "uuid", "user_id" "uuid", "project_name" "text", "end_date" "text", "project_status" "text", "profile_exists" boolean)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    SET "TimeZone" TO 'UTC'
    AS $$
  select p.id, p.owner_id, p.name::text, p.end_date::text,
    p.status::text, pr.id is not null
  from public.projects p
  left join public.profiles pr on pr.id = p.owner_id
  where p.end_date is not null and p.status = 'active'
  order by p.id
  offset greatest(p_offset, 0)
  limit least(greatest(p_limit, 1), 500);
$$;

ALTER FUNCTION "public"."notification_project_candidates"("p_offset" integer, "p_limit" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."notification_read_only_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if (to_jsonb(new) - 'is_read' - 'read_at') is distinct from
     (to_jsonb(old) - 'is_read' - 'read_at') then
    raise exception 'Only read state may be changed';
  end if;
  if old.is_read and not new.is_read then
    raise exception 'A read notification cannot be made unread';
  end if;
  return new;
end;
$$;

ALTER FUNCTION "public"."notification_read_only_update"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."notification_task_candidates"("p_offset" integer, "p_limit" integer) RETURNS TABLE("task_id" "uuid", "board_id" "uuid", "project_id" "uuid", "user_id" "uuid", "task_title" "text", "task_status" "text", "task_archived" boolean, "board_archived" boolean, "project_status" "text", "profile_exists" boolean, "deadline" "text", "last_activity_at" "text", "task_created_at" "text", "deadline_has_time" boolean)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    SET "TimeZone" TO 'UTC'
    AS $$
  select t.id, b.id, p.id, p.owner_id, t.title::text, t.status::text,
    coalesce(t.is_archived, false), coalesce(b.is_archived, false),
    p.status::text, pr.id is not null, t.deadline::text,
    coalesce(activity.created_at, t.updated_at, t.created_at)::text, t.created_at::text, t.deadline_has_time
  from public.kanban_tasks t
  join public.kanban_boards b on b.id = t.board_id
  join public.projects p on p.id = b.project_id
  left join public.profiles pr on pr.id = p.owner_id
  left join lateral (
    select l.created_at from public.task_activity_logs l
    where l.task_id = t.id
    order by l.created_at desc limit 1
  ) activity on true
  where p.status = 'active' and not coalesce(b.is_archived, false)
    and not coalesce(t.is_archived, false) and t.status <> 'completed'
  order by t.id
  offset greatest(p_offset, 0)
  limit least(greatest(p_limit, 1), 500);
$$;

ALTER FUNCTION "public"."notification_task_candidates"("p_offset" integer, "p_limit" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."owns_bookmark_task"("p_task_id" "uuid", "p_writable" boolean DEFAULT false) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists(select 1 from public.kanban_tasks t
    join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
    where t.id=p_task_id and p.owner_id=auth.uid()
      and (not p_writable or (p.status='active' and not b.is_archived and not t.is_archived and t.status<>'completed')))
$$;

ALTER FUNCTION "public"."owns_bookmark_task"("p_task_id" "uuid", "p_writable" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."queue_deleted_task_attachment"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  -- Queue only files the signed-in owner can remove via the Storage API.
  if split_part(old.storage_path, '/', 1) = auth.uid()::text
      and not exists (select 1 from public.task_attachments a where a.storage_path = old.storage_path) then
    insert into public.task_attachment_cleanup(user_id, storage_path)
      values (auth.uid(), old.storage_path) on conflict do nothing;
  end if;
  return old;
end;
$$;

ALTER FUNCTION "public"."queue_deleted_task_attachment"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."queue_ready_transcript_analysis"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if tg_op='UPDATE' and old.status='ready' then return new; end if;
  if new.status='ready' then perform public.enqueue_video_analysis(new.id,false); end if;
  return new;
end $$;

ALTER FUNCTION "public"."queue_ready_transcript_analysis"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."queue_resource_embedding_after_analysis"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.status='ready' then perform public.enqueue_resource_embedding(new.resource_id); end if;
  return new;
end $$;

ALTER FUNCTION "public"."queue_resource_embedding_after_analysis"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."queue_saved_resource_analysis"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if tg_op='UPDATE' and public.resource_analysis_version(to_jsonb(old),null)=public.resource_analysis_version(to_jsonb(new),null)
    and old.status is not distinct from new.status and old.moderation_hidden is not distinct from new.moderation_hidden then
    return new;
  end if;
  perform public.enqueue_resource_analysis(new.id,false);
  return new;
end $$;

ALTER FUNCTION "public"."queue_saved_resource_analysis"() OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."resource_extractions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "resource_id" "text" NOT NULL,
    "source_file_id" "text" NOT NULL,
    "source_version" "text" NOT NULL,
    "language" "text",
    "extracted_text" "text",
    "segments" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "storage_bucket" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "claim_token" "uuid",
    "lease_expires_at" timestamp with time zone,
    "next_attempt_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "error_code" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "extraction_type" "text" DEFAULT 'video_transcript'::"text" NOT NULL,
    CONSTRAINT "resource_extractions_extraction_type_check" CHECK (("extraction_type" = ANY (ARRAY['video_transcript'::"text", 'pdf_text'::"text", 'image_description'::"text"]))),
    CONSTRAINT "video_transcripts_attempt_count_check" CHECK (("attempt_count" >= 0)),
    CONSTRAINT "video_transcripts_claim_check" CHECK ((("status" <> 'processing'::"text") OR ("claim_token" IS NOT NULL))),
    CONSTRAINT "video_transcripts_lease_check" CHECK ((("status" = 'processing'::"text") = ("lease_expires_at" IS NOT NULL))),
    CONSTRAINT "video_transcripts_ready_check" CHECK ((("status" <> 'ready'::"text") OR (("extracted_text" IS NOT NULL) AND ("length"("btrim"("extracted_text")) > 0)))),
    CONSTRAINT "video_transcripts_segments_check" CHECK (("jsonb_typeof"("segments") = 'array'::"text")),
    CONSTRAINT "video_transcripts_source_check" CHECK (((("length"("btrim"("resource_id")) >= 1) AND ("length"("btrim"("resource_id")) <= 256)) AND (("length"("btrim"("source_file_id")) >= 1) AND ("length"("btrim"("source_file_id")) <= 256)) AND (("length"("btrim"("source_version")) >= 1) AND ("length"("btrim"("source_version")) <= 256)) AND (("length"("btrim"("storage_bucket")) >= 1) AND ("length"("btrim"("storage_bucket")) <= 100)) AND (("length"("btrim"("storage_path")) >= 1) AND ("length"("btrim"("storage_path")) <= 1024)))),
    CONSTRAINT "video_transcripts_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'processing'::"text", 'ready'::"text", 'failed'::"text"]))),
    CONSTRAINT "video_transcripts_transcript_text_check" CHECK (("length"("btrim"("extracted_text")) > 0))
);

ALTER TABLE "public"."resource_extractions" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."read_ready_resource_extraction"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text") RETURNS SETOF "public"."resource_extractions"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'storage', 'pg_temp'
    AS $$
  select t.* from public.learning_resources r
  join storage.objects o on o.bucket_id=p_storage_bucket and o.name=p_storage_path
  join public.resource_extractions t on t.resource_id=r.id::text
    and t.source_file_id=o.id::text
    and t.source_version=coalesce(nullif(to_jsonb(o)->>'version',''),
      nullif(o.metadata->>'eTag',''),nullif(o.metadata->>'etag',''),
      extract(epoch from o.updated_at)::text)
    and t.storage_bucket=o.bucket_id and t.storage_path=o.name
  where r.id=p_resource_id and r.external_url=p_external_url
    and public.resource_analysis_storage_key(r.external_url)=p_storage_bucket||'/'||p_storage_path
    and ((r.kind='Video' and t.extraction_type='video_transcript') or (public.is_pdf_resource(to_jsonb(r)) and t.extraction_type='pdf_text') or (public.is_image_resource(to_jsonb(r)) and t.extraction_type='image_description')) and r.moderation_hidden=false
    and r.status in ('draft','published') and t.status='ready';
$$;

ALTER FUNCTION "public"."read_ready_resource_extraction"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text") OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."video_transcripts" WITH ("security_invoker"='true') AS
 SELECT "id",
    "resource_id",
    "source_file_id",
    "source_version",
    "language",
    "extracted_text" AS "transcript_text",
    "segments",
    "created_at",
    "storage_bucket",
    "storage_path",
    "status",
    "attempt_count",
    "claim_token",
    "lease_expires_at",
    "next_attempt_at",
    "error_code",
    "updated_at"
   FROM "public"."resource_extractions";

ALTER VIEW "public"."video_transcripts" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."read_ready_video_transcript"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text") RETURNS SETOF "public"."video_transcripts"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
 select v.* from public.video_transcripts v join public.read_ready_resource_extraction(
 p_resource_id,p_external_url,p_storage_bucket,p_storage_path) e on e.id=v.id
 where e.extraction_type='video_transcript'
$$;

ALTER FUNCTION "public"."read_ready_video_transcript"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."read_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare s public.task_recommendation_sets%rowtype; task public.kanban_tasks%rowtype; items jsonb; sources jsonb;
begin
 select t.* into task from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id
 join public.projects p on p.id=b.project_id where t.id=p_task_id and p.owner_id=p_user_id;
 if not found then raise exception 'Task access denied' using errcode='42501'; end if;
 select * into s from public.task_recommendation_sets where task_id=p_task_id;
 select coalesce(jsonb_agg(jsonb_build_object('resource_id',r.id,'title',r.title,'summary',coalesce(r.summary,''),'type',r.kind) order by i.position),'[]'),
 coalesce(jsonb_agg(jsonb_build_object('resource_id',r.id,'source_version',i.source_version) order by i.position),'[]') into items,sources
 from public.task_recommendation_items i join public.recommendation_resources_for_recipient(p_user_id,
   array(select resource_id from public.task_recommendation_items where task_id=p_task_id)) r on r.id=i.resource_id
 where i.task_id=p_task_id;
 return jsonb_build_object('generated',s.generation_id is not null,'generation_id',s.generation_id,'generated_at',s.generated_at,
 'stalled_at',s.stalled_at,'task_version',s.task_version,'sources',sources,'recommendations',items,
 'status',case when jsonb_array_length(items)>0 then 'ok' else 'empty' end);
end $$;

ALTER FUNCTION "public"."read_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."recommendation_jaccard"("a" "text"[], "b" "text"[]) RETURNS double precision
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select coalesce((select count(*)::double precision from
    (select unnest(a) intersect select unnest(b)) i) /
    nullif((select count(*) from (select unnest(a) union select unnest(b)) u),0),0)
$$;

ALTER FUNCTION "public"."recommendation_jaccard"("a" "text"[], "b" "text"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."recommendation_load_owned_task"("p_task_id" "uuid", "p_user_id" "uuid") RETURNS TABLE("title" "text", "description" "text", "is_stalled" boolean, "source_version" "text")
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select * from public.recommendation_load_owned_task(p_task_id,p_user_id,'automatic');
$$;

ALTER FUNCTION "public"."recommendation_load_owned_task"("p_task_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."recommendation_load_owned_task"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text") RETURNS TABLE("title" "text", "description" "text", "is_stalled" boolean, "source_version" "text")
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
begin
  if p_mode is null or p_mode not in ('automatic','manual') then
    raise exception 'Invalid recommendation mode' using errcode='22023';
  end if;
  return query
  select case when (p_mode='manual' or t.is_stalled) and t.status<>'completed' then t.title::text end,
    case when (p_mode='manual' or t.is_stalled) and t.status<>'completed' then coalesce(t.description,'') end,
    t.is_stalled and t.status<>'completed',
    encode(sha256(convert_to(jsonb_build_array(t.title,t.description,t.is_stalled,t.status)::text,'UTF8')),'hex')
  from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id join public.projects p on p.id=b.project_id
  where t.id=p_task_id and p.owner_id=p_user_id and p.status='active' and not b.is_archived and not t.is_archived
    and (p_mode='automatic' or t.status<>'completed');
end
$$;

ALTER FUNCTION "public"."recommendation_load_owned_task"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."recommendation_resources_for_recipient"("p_user_id" "uuid", "p_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS TABLE("id" "uuid", "title" "text", "summary" "text", "kind" "text", "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare previous_claims text := current_setting('request.jwt.claims',true);
  previous_sub text := current_setting('request.jwt.claim.sub',true);
  previous_role text := current_setting('request.jwt.claim.role',true);
  claims jsonb;
begin
  select jsonb_build_object('sub',u.id,'role','authenticated','aud','authenticated',
    'aal','aal1','email',u.email,'app_metadata',coalesce(u.raw_app_meta_data,'{}'::jsonb),
    'user_metadata',coalesce(u.raw_user_meta_data,'{}'::jsonb)) into claims
  from auth.users u where u.id=p_user_id;
  if claims is null then return; end if;
  perform set_config('request.jwt.claims',claims::text,true);
  perform set_config('request.jwt.claim.sub',p_user_id::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  return query select * from public.recommendation_rls_resources(p_ids);
  perform set_config('request.jwt.claims',coalesce(previous_claims,''),true);
  perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
  perform set_config('request.jwt.claim.role',coalesce(previous_role,''),true);
exception when others then
  perform set_config('request.jwt.claims',coalesce(previous_claims,''),true);
  perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
  perform set_config('request.jwt.claim.role',coalesce(previous_role,''),true);
  raise;
end $$;

ALTER FUNCTION "public"."recommendation_resources_for_recipient"("p_user_id" "uuid", "p_ids" "uuid"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."recommendation_rls_resources"("p_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS TABLE("id" "uuid", "title" "text", "summary" "text", "kind" "text", "updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
  select r.id,r.title::text,r.summary::text,r.kind::text,r.updated_at
  from public.learning_resources r
  where r.status='published' and not r.moderation_hidden
    and (p_ids is null or r.id=any(p_ids));
$$;

GRANT CREATE ON SCHEMA public TO authenticated;
ALTER FUNCTION "public"."recommendation_rls_resources"("p_ids" "uuid"[]) OWNER TO "authenticated";
REVOKE CREATE ON SCHEMA public FROM authenticated;

CREATE OR REPLACE FUNCTION "public"."register_project_push_device"("p_fcm_token" "text", "p_platform" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_fcm_token is null or length(btrim(p_fcm_token)) not between 1 and 4096
      or p_fcm_token ~ '[[:space:]]'
      or p_platform is null or p_platform not in ('android', 'ios') then
    raise exception 'Invalid push device registration' using errcode = '22023';
  end if;
  insert into public.project_push_devices (user_id, fcm_token, platform)
    values (current_user_id, p_fcm_token, p_platform)
  on conflict (fcm_token) do update set
    user_id = current_user_id,
    platform = excluded.platform,
    is_active = true,
    last_seen_at = now(),
    updated_at = now();
end;
$$;

ALTER FUNCTION "public"."register_project_push_device"("p_fcm_token" "text", "p_platform" "text") OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."task_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "file_name" character varying(255) NOT NULL,
    "storage_path" "text" NOT NULL,
    "mime_type" character varying(100),
    "file_size_bytes" bigint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "attachments_file_name_not_blank" CHECK (("length"(TRIM(BOTH FROM "file_name")) > 0)),
    CONSTRAINT "attachments_file_size_valid" CHECK ((("file_size_bytes" IS NULL) OR ("file_size_bytes" >= 0))),
    CONSTRAINT "attachments_storage_path_not_blank" CHECK (("length"(TRIM(BOTH FROM "storage_path")) > 0))
);

ALTER TABLE "public"."task_attachments" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."register_task_attachment"("p_task_id" "uuid", "p_file_name" "text", "p_storage_path" "text", "p_mime_type" "text", "p_file_size" bigint) RETURNS "public"."task_attachments"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_board_id uuid; attachment public.task_attachments;
begin
  select t.board_id into v_board_id from public.kanban_tasks t where t.id = p_task_id;
  perform public.assert_owned_kanban_board(v_board_id);
  if p_storage_path is null or p_file_size is null or p_file_name is null
      or length(btrim(p_file_name)) not between 1 and 255
      or p_storage_path not like auth.uid()::text || '/' || p_task_id::text || '/%'
      or p_file_size not between 1 and 10485760 then raise exception 'Invalid attachment'; end if;
  insert into public.task_attachments (task_id, file_name, storage_path, mime_type, file_size_bytes)
    values (p_task_id, p_file_name, p_storage_path, p_mime_type, p_file_size)
    returning * into attachment;
  insert into public.task_activity_logs (task_id, action, old_values, new_values)
    values (p_task_id, 'attachment_added', '{}'::jsonb, jsonb_build_object('file_name', p_file_name));
  return attachment;
end;
$$;

ALTER FUNCTION "public"."register_task_attachment"("p_task_id" "uuid", "p_file_name" "text", "p_storage_path" "text", "p_mime_type" "text", "p_file_size" bigint) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."renew_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_lease_seconds" integer DEFAULT 900) RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_now timestamptz := clock_timestamp();
begin
  if p_lease_seconds is null or p_lease_seconds not between 60 and 3600 then
    raise exception 'Invalid lease duration' using errcode = '22023';
  end if;
  update public.resource_extractions set
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    updated_at = v_now
  where id = p_extraction_id and claim_token = p_claim_token
    and status = 'processing' and lease_expires_at > v_now;
  return found;
end;
$$;

ALTER FUNCTION "public"."renew_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_lease_seconds" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."renew_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_lease_seconds" integer DEFAULT 900) RETURNS boolean
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
 select public.renew_resource_extraction(p_transcript_id,p_claim_token,p_lease_seconds) $$;

ALTER FUNCTION "public"."renew_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_lease_seconds" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."reorder_kanban_tasks"("p_tasks" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_board_id uuid; expected integer; matched integer;
begin
  if jsonb_typeof(p_tasks) is distinct from 'array' then raise exception 'Invalid task order'; end if;
  expected := jsonb_array_length(p_tasks);
  if expected = 0 then return; end if;
  select t.board_id into v_board_id from public.kanban_tasks t
    where t.id = (p_tasks->0->>'id')::uuid;
  perform public.assert_owned_kanban_board(v_board_id);
  select count(distinct t.id) into matched
    from public.kanban_tasks t join jsonb_to_recordset(p_tasks) x(id uuid, sort_order bigint)
      on x.id = t.id where t.board_id = v_board_id and x.sort_order is not null;
  if matched <> expected then raise exception 'Invalid task order'; end if;
  update public.kanban_tasks t set sort_order = x.sort_order
    from jsonb_to_recordset(p_tasks) x(id uuid, sort_order bigint) where x.id = t.id;
end;
$$;

ALTER FUNCTION "public"."reorder_kanban_tasks"("p_tasks" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."reorder_task_checklist"("p_task_id" "uuid", "p_items" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_board_id uuid; expected integer; matched integer;
begin
  select t.board_id into v_board_id from public.kanban_tasks t where t.id = p_task_id;
  perform public.assert_owned_kanban_board(v_board_id);
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Invalid checklist order'; end if;
  expected := jsonb_array_length(p_items);
  select count(distinct c.id) into matched from public.task_checklist_items c
    join jsonb_to_recordset(p_items) x(id uuid, position integer) on x.id = c.id
    where c.task_id = p_task_id and x.position >= 0;
  if matched <> expected or (select count(distinct x.position)
    from jsonb_to_recordset(p_items) x(position integer)) <> expected then
    raise exception 'Invalid checklist order';
  end if;
  update public.task_checklist_items c set position = x.position
    from jsonb_to_recordset(p_items) x(id uuid, position integer) where x.id = c.id;
  insert into public.task_activity_logs (task_id, action, old_values, new_values)
    values (p_task_id, 'checklist_updated', '{}'::jsonb, '{"change":"reordered"}'::jsonb);
end;
$$;

ALTER FUNCTION "public"."reorder_task_checklist"("p_task_id" "uuid", "p_items" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."replace_generated_task_list"("p_board_id" "uuid", "p_request_id" "text", "p_expected_version" "text", "p_tasks" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare receipt public.kanban_write_requests; payload jsonb;
 receipt_id text; saved integer; archived_at timestamptz;
begin
 if auth.uid() is null or p_request_id is null or length(p_request_id) not between 16 and 128
 or p_expected_version is null then raise exception 'Invalid replacement request' using errcode='22023'; end if;
 receipt_id:='replace-plan:'||encode(sha256(convert_to(p_request_id,'UTF8')),'hex');
 payload:=jsonb_build_object('version',p_expected_version,'tasks',p_tasks);
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||receipt_id,0));
 -- Short confirmation-only table locks also exclude checklist/milestone writers
 -- that do not take the board lock. No locks are held during AI or preview.
 lock table projects,kanban_boards,kanban_tasks,project_milestones,task_checklist_items in share row exclusive mode;
 if not exists(select 1 from kanban_boards b join projects p on p.id=b.project_id
 where b.id=p_board_id and p.owner_id=auth.uid()) then raise exception 'Board access denied' using errcode='42501'; end if;
 select * into receipt from kanban_write_requests where user_id=auth.uid() and request_id=receipt_id;
 if found then
  if receipt.board_id is distinct from p_board_id or receipt.payload is distinct from payload then
   raise exception 'Request identifier already used' using errcode='22023'; end if;
  return receipt.saved_count;
 end if;
 perform public.assert_owned_kanban_board(p_board_id);
 if (public.task_list_replacement_context(p_board_id)->>'version') is distinct from p_expected_version then
  raise exception 'Board changed. Cancel this preview and regenerate.' using errcode='40001'; end if;
 if jsonb_typeof(p_tasks) is distinct from 'array' or jsonb_array_length(p_tasks) not between 1 and 12 then
  raise exception 'Invalid replacement tasks' using errcode='22023'; end if;
 if (select count(distinct regexp_replace(lower(btrim(value->>'title')),'[^[:alnum:]]+',' ','g')) from jsonb_array_elements(p_tasks)) <> jsonb_array_length(p_tasks) then
  raise exception 'Duplicate replacement titles' using errcode='22023'; end if;
 archived_at:=clock_timestamp();
 with archived as (
  update kanban_tasks set is_archived=true,updated_at=archived_at,
   elapsed_seconds=elapsed_seconds+case when tracking_started_at is null then 0
    else greatest(0::bigint,floor(extract(epoch from (archived_at-tracking_started_at)))::bigint) end,
   tracking_started_at=null
  where board_id=p_board_id and not is_archived returning id
 ) insert into task_activity_logs(task_id,action,old_values,new_values)
 select id,'archived','{}'::jsonb,jsonb_build_object('reason','task_list_replaced') from archived;
 saved:=public.save_replacement_task_drafts(p_board_id,receipt_id||':drafts',p_tasks);
 insert into kanban_write_requests(user_id,request_id,board_id,payload,saved_count)
 values(auth.uid(),receipt_id,p_board_id,payload,saved);
 return saved;
end $$;

ALTER FUNCTION "public"."replace_generated_task_list"("p_board_id" "uuid", "p_request_id" "text", "p_expected_version" "text", "p_tasks" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."replay_skilltrack_write"("p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  owner uuid := auth.uid();
  receipt public.kanban_write_requests;
  receipt_key text := public.skilltrack_receipt_key(p_operation, p_request_id);
begin
  if owner is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_request_id is null or length(p_request_id) not between 16 and 128
      or p_operation is null or p_operation not in
        ('create_project', 'confirm_plan', 'create_task', 'move', 'archive', 'restore', 'resume') then
    raise exception 'Invalid request identifier' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(owner::text || ':' || receipt_key, 0));
  select * into receipt from public.kanban_write_requests
    where user_id = owner and request_id = receipt_key;
  if not found then return null; end if;
  if receipt.payload->>'request_id' is distinct from p_request_id
      or receipt.payload->'request' is distinct from p_payload then
    raise exception 'Request identifier already used for another payload' using errcode = '22023';
  end if;
  perform b.id from public.kanban_boards b join public.projects p on p.id = b.project_id
    where b.id = (receipt.payload->>'board_id')::uuid and p.owner_id = owner for update of b;
  if not found then raise exception 'Project board unavailable' using errcode = '42501'; end if;
  return receipt.payload->'result';
end;
$$;

ALTER FUNCTION "public"."replay_skilltrack_write"("p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."resource_analysis_candidates"("p_resource_id" "uuid", "p_allow_draft" boolean) RETURNS TABLE("resource_id" "uuid", "transcript_id" "uuid", "source_file_id" "text", "source_version" "text", "content_version" "text")
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select r.id,t.id,t.source_file_id,t.source_version,
    public.resource_analysis_version(to_jsonb(r),to_jsonb(t))
  from public.learning_resources r
  left join public.video_transcripts t on (r.kind='Video' or (public.is_pdf_resource(to_jsonb(r)) or public.is_image_resource(to_jsonb(r)))) and t.resource_id=r.id::text
    and t.status='ready'
    and t.storage_bucket||'/'||t.storage_path=public.resource_analysis_storage_key(r.external_url)
    and exists(select 1 from public.read_ready_resource_extraction(r.id,r.external_url,t.storage_bucket,t.storage_path) current_source where current_source.id=t.id)
  where (p_resource_id is null or r.id=p_resource_id) and not r.moderation_hidden
    and (r.status='published' or (p_allow_draft and p_resource_id is not null and r.status='draft'))
    and (((r.kind='Video' or (public.is_pdf_resource(to_jsonb(r)) or public.is_image_resource(to_jsonb(r)))) and t.id is not null)
      or (r.kind<>'Video' and not (public.is_pdf_resource(to_jsonb(r)) or public.is_image_resource(to_jsonb(r))) and nullif(btrim(r.body),'') is not null));
$$;

ALTER FUNCTION "public"."resource_analysis_candidates"("p_resource_id" "uuid", "p_allow_draft" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."resource_analysis_storage_key"("p_url" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE STRICT
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
declare encoded text; bytes bytea:=''::bytea; pos integer:=1; ch text;
begin
  encoded:=substring(p_url from '^https://[^/?#@]+/storage/v1/object/(?:public|authenticated)/([^?#]+)$');
  if encoded is null then return null; end if;
  while pos<=length(encoded) loop
    ch:=substr(encoded,pos,1);
    if ch='%' then
      bytes:=bytes||decode(substr(encoded,pos+1,2),'hex');pos:=pos+3;
    else bytes:=bytes||convert_to(ch,'UTF8');pos:=pos+1;
    end if;
  end loop;
  return convert_from(bytes,'UTF8');
exception when others then return null;
end $_$;

ALTER FUNCTION "public"."resource_analysis_storage_key"("p_url" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."resource_analysis_version"("p_resource" "jsonb", "p_transcript" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select encode(sha256(convert_to(jsonb_build_array(
    p_resource->'id',p_resource->'author_id',p_resource->'title',p_resource->'summary',
    p_resource->'category',p_resource->'body',p_resource->'tags',p_resource->'kind',
    p_resource->'external_url',p_transcript->'id',p_transcript->'source_file_id',
    p_transcript->'source_version',coalesce(p_transcript->'extracted_text',p_transcript->'transcript_text'))::text,'UTF8')),'hex');
$$;

ALTER FUNCTION "public"."resource_analysis_version"("p_resource" "jsonb", "p_transcript" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."resource_extraction_candidates"("p_limit" integer DEFAULT 25, "p_after_id" "uuid" DEFAULT NULL::"uuid", "p_draft_resource_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "external_url" "text", "kind" "text")
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid batch size'; end if;
 return query select r.id,r.external_url,r.kind::text from public.learning_resources r
 where not r.moderation_hidden and (r.kind='Video' or public.is_pdf_resource(to_jsonb(r)))
 and ((p_draft_resource_id is null and r.status='published' and (p_after_id is null or r.id>p_after_id))
 or (p_draft_resource_id=r.id and r.status='draft')) order by r.id limit p_limit;
end $$;

ALTER FUNCTION "public"."resource_extraction_candidates"("p_limit" integer, "p_after_id" "uuid", "p_draft_resource_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_generated_tasks"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
declare
  receipt public.kanban_write_requests;
  draft jsonb;
  task_id uuid;
  next_order bigint;
  saved integer := 0;
  checklist jsonb;
  normalized_title text;
begin
  if auth.uid() is null or p_request_id is null
      or length(p_request_id) not between 16 and 128
      or jsonb_typeof(p_tasks) is distinct from 'array'
      or jsonb_array_length(p_tasks) not between 1 and 12 then
    raise exception 'Invalid generated task request' using errcode = '22023';
  end if;
  -- Serialize a request across boards as well as concurrent writers to a board.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_request_id, 0));
  perform public.assert_owned_kanban_board(p_board_id);
  select * into receipt from public.kanban_write_requests
    where user_id = auth.uid() and request_id = p_request_id;
  if found then
    if receipt.board_id <> p_board_id or receipt.payload <> p_tasks then
      raise exception 'Request identifier already used for another payload' using errcode = '22023';
    end if;
    return receipt.saved_count;
  end if;
  select coalesce(max(sort_order), 0) into next_order
    from public.kanban_tasks where board_id = p_board_id
      and status = 'todo' and not is_archived;
  for draft in select value from jsonb_array_elements(p_tasks) loop
    checklist := coalesce(draft->'checklist', '[]'::jsonb);
    if jsonb_typeof(draft) is distinct from 'object'
        or jsonb_typeof(draft->'title') is distinct from 'string'
        or length(btrim(draft->>'title')) not between 1 and 150
        or jsonb_typeof(draft->'description') is distinct from 'string'
        or length(btrim(draft->>'description')) not between 1 and 1000
        or coalesce(draft->>'priority', '') not in ('low', 'medium', 'high')
        or coalesce(draft->>'deadline', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        or jsonb_typeof(checklist) is distinct from 'array' then
      raise exception 'Invalid generated task' using errcode = '22023';
    end if;
    -- Casting rejects invalid calendar dates; the transaction is rolled back.
    perform (draft->>'deadline')::date;
    if jsonb_array_length(checklist) > 5 or exists (
      select 1 from jsonb_array_elements(checklist) item
      where jsonb_typeof(item) <> 'string'
        or length(btrim(item #>> '{}')) not between 1 and 150
    ) or (select count(distinct lower(btrim(value #>> '{}')))
          from jsonb_array_elements(checklist)) <> jsonb_array_length(checklist) then
      raise exception 'Invalid generated checklist' using errcode = '22023';
    end if;
    normalized_title := regexp_replace(lower(btrim(draft->>'title')), '[^[:alnum:]]+', ' ', 'g');
    if exists (select 1 from public.kanban_tasks t where t.board_id = p_board_id
      and regexp_replace(lower(btrim(t.title)), '[^[:alnum:]]+', ' ', 'g') = normalized_title) then
      continue;
    end if;
    next_order := next_order + 1000;
    insert into public.kanban_tasks
      (board_id, title, description, priority, status, deadline, deadline_has_time, sort_order, is_archived)
    values (p_board_id, btrim(draft->>'title'), btrim(draft->>'description'),
      draft->>'priority', 'todo', (((draft->>'deadline')::date + 1)::timestamp at time zone 'Asia/Kuala_Lumpur') - interval '1 millisecond', false, next_order, false)
    returning id into task_id;
    insert into public.task_checklist_items (task_id, title, position, is_completed)
      select task_id, btrim(item.value #>> '{}'), (item.ordinality - 1)::integer, false
      from jsonb_array_elements(checklist) with ordinality item;
    insert into public.task_activity_logs (task_id, action, old_values, new_values)
      values (task_id, 'created', '{}'::jsonb, jsonb_build_object('title', draft->>'title'));
    saved := saved + 1;
  end loop;
  insert into public.kanban_write_requests (user_id, request_id, board_id, payload, saved_count)
    values (auth.uid(), p_request_id, p_board_id, p_tasks, saved);
  return saved;
end;
$_$;

ALTER FUNCTION "public"."save_generated_tasks"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_generated_tasks_with_milestones"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
declare
  receipt public.kanban_write_requests;
  draft jsonb;
  task_id uuid;
  next_order bigint;
  saved integer := 0;
  checklist jsonb;
  normalized_title text;
  project uuid;
  milestone jsonb;
  milestone_key text;
  milestone_uuid uuid;
  milestone_map jsonb := '{}'::jsonb;
  milestone_metadata jsonb := '{}'::jsonb;
  next_position integer;
  versioned_payload jsonb := jsonb_build_object('format', 'milestones-v1', 'tasks', p_tasks);
begin
  if auth.uid() is null or p_request_id is null
      or length(p_request_id) not between 16 and 128
      or jsonb_typeof(p_tasks) is distinct from 'array'
      or jsonb_array_length(p_tasks) not between 1 and 12 then
    raise exception 'Invalid generated task request' using errcode = '22023';
  end if;
  -- Serialize a request across boards as well as concurrent writers to a board.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_request_id, 0));
  perform public.assert_owned_kanban_board(p_board_id);
  select * into receipt from public.kanban_write_requests
    where user_id = auth.uid() and request_id = p_request_id;
  if found then
    if receipt.board_id <> p_board_id or receipt.payload <> versioned_payload then
      raise exception 'Request identifier already used for another payload' using errcode = '22023';
    end if;
    return receipt.saved_count;
  end if;
  select project_id into project from public.kanban_boards where id = p_board_id;
  -- Serialize milestone positions across boards of the same project.
  perform 1 from public.projects where id = project for update;
  select coalesce(max(position), -1) + 1 into next_position
    from public.project_milestones where project_id = project;
  select coalesce(max(sort_order), 0) into next_order
    from public.kanban_tasks where board_id = p_board_id
      and status = 'todo' and not is_archived;
  for draft in select value from jsonb_array_elements(p_tasks) loop
    checklist := coalesce(draft->'checklist', '[]'::jsonb);
    if jsonb_typeof(draft) is distinct from 'object'
        or jsonb_typeof(draft->'title') is distinct from 'string'
        or length(btrim(draft->>'title')) not between 1 and 150
        or jsonb_typeof(draft->'description') is distinct from 'string'
        or length(btrim(draft->>'description')) not between 1 and 1000
        or coalesce(draft->>'priority', '') not in ('low', 'medium', 'high')
        or coalesce(draft->>'deadline', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        or jsonb_typeof(checklist) is distinct from 'array' then
      raise exception 'Invalid generated task' using errcode = '22023';
    end if;
    -- Casting rejects invalid calendar dates; the transaction is rolled back.
    perform (draft->>'deadline')::date;
    if jsonb_array_length(checklist) > 5 or exists (
      select 1 from jsonb_array_elements(checklist) item
      where jsonb_typeof(item) <> 'string'
        or length(btrim(item #>> '{}')) not between 1 and 150
    ) or (select count(distinct lower(btrim(value #>> '{}')))
          from jsonb_array_elements(checklist)) <> jsonb_array_length(checklist) then
      raise exception 'Invalid generated checklist' using errcode = '22023';
    end if;
    milestone_uuid := null;
    milestone := draft->'milestone';
    if milestone is not null and milestone <> 'null'::jsonb then
      milestone_key := milestone->>'localId';
      if jsonb_typeof(milestone) is distinct from 'object'
          or coalesce(length(btrim(milestone_key)), 0) not between 1 and 128
          or jsonb_typeof(milestone->'title') is distinct from 'string'
          or length(btrim(milestone->>'title')) not between 1 and 150
          or coalesce(milestone->>'position', '') !~ '^[0-9]+$'
          or (milestone->>'position')::bigint > 2147483647 then
        raise exception 'Invalid milestone' using errcode = '22023';
      end if;
      if milestone_metadata ? milestone_key and milestone_metadata->milestone_key <> milestone then
        raise exception 'Inconsistent milestone identity' using errcode = '22023';
      end if;
      milestone_metadata := milestone_metadata || jsonb_build_object(milestone_key, milestone);
      if (select count(*) from jsonb_object_keys(milestone_metadata)) > 5 then
        raise exception 'Too many milestones' using errcode = '22023';
      end if;
      if nullif(milestone->>'existingMilestoneId', '') is not null then
        select id into milestone_uuid from public.project_milestones
          where id = (milestone->>'existingMilestoneId')::uuid and project_id = project;
        if not found then
          raise exception 'Milestone unavailable for this project' using errcode = '42501';
        end if;
      end if;
    end if;
    normalized_title := regexp_replace(lower(btrim(draft->>'title')), '[^[:alnum:]]+', ' ', 'g');
    if exists (select 1 from public.kanban_tasks t where t.board_id = p_board_id
      and regexp_replace(lower(btrim(t.title)), '[^[:alnum:]]+', ' ', 'g') = normalized_title) then
      continue;
    end if;
    -- Create only groups containing at least one new task, after duplicate validation.
    if milestone is not null and milestone <> 'null'::jsonb and milestone_uuid is null then
      milestone_uuid := (milestone_map->>milestone_key)::uuid;
      if milestone_uuid is null then
        insert into public.project_milestones(project_id, title, position)
          values (project, btrim(milestone->>'title'), next_position)
          returning id into milestone_uuid;
        next_position := next_position + 1;
        milestone_map := milestone_map || jsonb_build_object(milestone_key, milestone_uuid);
      end if;
    end if;
    next_order := next_order + 1000;
    insert into public.kanban_tasks
      (board_id, title, description, priority, status, deadline, deadline_has_time, sort_order, is_archived, milestone_id)
    values (p_board_id, btrim(draft->>'title'), btrim(draft->>'description'),
      draft->>'priority', 'todo', (((draft->>'deadline')::date + 1)::timestamp at time zone 'Asia/Kuala_Lumpur') - interval '1 millisecond', false, next_order, false, milestone_uuid)
    returning id into task_id;
    insert into public.task_checklist_items (task_id, title, position, is_completed)
      select task_id, btrim(item.value #>> '{}'), (item.ordinality - 1)::integer, false
      from jsonb_array_elements(checklist) with ordinality item;
    insert into public.task_activity_logs (task_id, action, old_values, new_values)
      values (task_id, 'created', '{}'::jsonb, jsonb_build_object('title', draft->>'title'));
    saved := saved + 1;
  end loop;
  insert into public.kanban_write_requests (user_id, request_id, board_id, payload, saved_count)
    values (auth.uid(), p_request_id, p_board_id, versioned_payload, saved);
  return saved;
end;
$_$;

ALTER FUNCTION "public"."save_generated_tasks_with_milestones"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_kanban_task_edit"("p_task_id" "uuid", "p_expected_updated_at" timestamp with time zone, "p_request_id" "text", "p_changes" "jsonb", "p_add_tag_ids" "uuid"[], "p_remove_tag_ids" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    SET "TimeZone" TO 'UTC'
    AS $$
declare
  owner uuid := auth.uid();
  board uuid;
  previous public.kanban_tasks;
  changes public.kanban_tasks;
  receipt public.kanban_write_requests;
  payload jsonb := jsonb_build_object('format', 'task-edit-v1', 'task_id', p_task_id,
    'expected_updated_at', p_expected_updated_at, 'changes', p_changes,
    'add_tag_ids', p_add_tag_ids, 'remove_tag_ids', p_remove_tag_ids);
  destination_order bigint;
begin
  if owner is null then
    raise exception 'Sign in to edit tasks' using errcode = '42501';
  end if;
  if p_request_id is null or length(p_request_id) not between 16 and 128
      or p_expected_updated_at is null
      or p_add_tag_ids is null or p_remove_tag_ids is null
      or p_add_tag_ids && p_remove_tag_ids
      or jsonb_typeof(p_changes) is distinct from 'object'
      or not (p_changes ?& array['title','description','status','priority','deadline','deadline_has_time','milestone_id'])
      or coalesce(p_changes->>'status', '') not in ('todo','in_progress','completed')
      or coalesce(p_changes->>'priority', '') not in ('low','medium','high')
      or coalesce(btrim(p_changes->>'title'), '') = '' then
    raise exception 'Invalid task edit' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(owner::text || p_request_id, 0));
  select t.board_id into board from public.kanban_tasks t where t.id = p_task_id;
  perform public.assert_owned_kanban_board(board);
  select * into previous from public.kanban_tasks t
    where t.id = p_task_id and t.board_id = board and not coalesce(t.is_archived, false)
    for update;
  if not found then raise exception 'Task unavailable' using errcode = '42501'; end if;

  select * into receipt from public.kanban_write_requests
    where user_id = owner and request_id = p_request_id;
  if found then
    if receipt.board_id <> board or receipt.payload <> payload then
      raise exception 'Request identifier already used for another payload' using errcode = '22023';
    end if;
  else
    if previous.updated_at is distinct from p_expected_updated_at then
      raise exception 'Task changed. Refresh it and try again.' using errcode = '40001';
    end if;
    changes := jsonb_populate_record(null::public.kanban_tasks, p_changes);
    if exists (
      select 1 from unnest(p_add_tag_ids) as requested(id)
      left join public.task_tags tag on tag.id = requested.id and tag.owner_id = owner
      where tag.id is null
    ) then
      raise exception 'Tag unavailable' using errcode = '42501';
    end if;

    if previous.status is distinct from changes.status then
      select coalesce(max(t.sort_order), 0) + 1000 into destination_order
        from public.kanban_tasks t where t.board_id = board and not coalesce(t.is_archived, false)
        and t.status = changes.status;
      perform public.update_kanban_task_tracking(
        p_task_id, 'move', p_expected_updated_at, changes.status::text, destination_order
      );
    end if;

    update public.kanban_tasks set title = btrim(changes.title), description = changes.description,
      priority = changes.priority, deadline = changes.deadline,
      deadline_has_time = case when changes.deadline is not null then changes.deadline_has_time end,
      milestone_id = changes.milestone_id, updated_at = clock_timestamp()
      where id = p_task_id;

    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      values (p_task_id, 'updated', '{}'::jsonb, jsonb_build_object('title', btrim(changes.title)));
    if previous.status is distinct from changes.status then
      insert into public.task_activity_logs(task_id, action, old_values, new_values)
        values (p_task_id, case when changes.status = 'completed' then 'completed'
          when previous.status = 'completed' then 'reopened' else 'moved' end,
          jsonb_build_object('status', previous.status), jsonb_build_object('status', changes.status));
    end if;

    with removed as (
      delete from public.task_tag_links
      where task_id = p_task_id and tag_id = any(p_remove_tag_ids) returning tag_id
    )
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      select p_task_id, 'tag_removed', jsonb_build_object('tag_id', tag_id), '{}'::jsonb
      from removed;

    with added as (
      insert into public.task_tag_links(task_id, tag_id)
      select p_task_id, id from unnest(p_add_tag_ids) as requested(id)
      on conflict (task_id, tag_id) do nothing returning tag_id
    )
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      select p_task_id, 'tag_added', '{}'::jsonb, jsonb_build_object('tag_id', tag_id)
      from added;

    insert into public.kanban_write_requests(user_id, request_id, board_id, payload, saved_count)
      values (owner, p_request_id, board, payload, 1);
  end if;

  -- Read after activity triggers, which may have updated the stalled state.
  return (select jsonb_build_object(
    'task', to_jsonb(t),
    'tags', coalesce((select jsonb_agg(to_jsonb(tag) order by tag.id)
      from public.task_tag_links link join public.task_tags tag on tag.id = link.tag_id
      where link.task_id = t.id), '[]'::jsonb),
    'checklist', coalesce((select jsonb_agg(to_jsonb(i) order by i.position, i.id)
      from public.task_checklist_items i where i.task_id = t.id), '[]'::jsonb),
    'attachments', coalesce((select jsonb_agg(to_jsonb(a) order by a.id)
      from public.task_attachments a where a.task_id = t.id), '[]'::jsonb))
    from public.kanban_tasks t where t.id = p_task_id);
end;
$$;

ALTER FUNCTION "public"."save_kanban_task_edit"("p_task_id" "uuid", "p_expected_updated_at" timestamp with time zone, "p_request_id" "text", "p_changes" "jsonb", "p_add_tag_ids" "uuid"[], "p_remove_tag_ids" "uuid"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_new_skilltrack_project"("p_request_id" "text", "p_name" "text", "p_description" "text", "p_constraints" "text", "p_start_date" "date", "p_end_date" "date", "p_tasks" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  owner uuid := auth.uid();
  project public.projects;
  board uuid;
  normalized_constraints text := nullif(btrim(p_constraints), '');
  operation text := case when p_tasks is null then 'create_project' else 'confirm_plan' end;
  payload jsonb := jsonb_build_object('name', p_name, 'description', p_description,
    'constraints', p_constraints, 'start_date', p_start_date, 'end_date', p_end_date, 'tasks', p_tasks);
  result jsonb;
  saved integer := 0;
begin
  result := public.replay_skilltrack_write(operation, p_request_id, payload);
  if result is not null then return result; end if;

  if coalesce(length(btrim(p_name)), 0) not between 1 and 150
      or length(normalized_constraints) > 1000
      or p_start_date > p_end_date then
    raise exception 'Invalid project fields' using errcode = '22023';
  end if;
  if p_tasks is not null and (jsonb_typeof(p_tasks) is distinct from 'array'
      or p_start_date is null or p_end_date is null
      or coalesce(length(btrim(p_description)), 0) not between 1 and 4000) then
    raise exception 'Invalid generated project' using errcode = '22023';
  end if;

  begin
    insert into public.projects(owner_id, name, description, constraints_text, status, start_date, end_date)
      values (owner, btrim(p_name), nullif(btrim(p_description), ''), normalized_constraints,
        'active', p_start_date, p_end_date) returning * into project;
    insert into public.kanban_boards(project_id, name)
      values (project.id, 'Kanban Board') returning id into board;
  exception when others then
    raise exception using errcode = SQLSTATE, message = SQLERRM, hint = 'skilltrack_project_setup';
  end;

  if p_tasks is not null then
    if exists (select 1 from jsonb_array_elements(p_tasks) d
      where jsonb_typeof(d->'milestone') = 'object') then
      saved := public.save_generated_tasks_with_milestones(board, gen_random_uuid()::text, p_tasks);
    else
      saved := public.save_generated_tasks(board, gen_random_uuid()::text, p_tasks);
    end if;
    -- A newly created board has no existing tasks. A partial batch is invalid.
    if saved <> jsonb_array_length(p_tasks) then
      raise exception 'Generated plan contains duplicate tasks' using errcode = '22023';
    end if;
  end if;

  result := jsonb_build_object('project', to_jsonb(project), 'board_id', board, 'total_task_count', saved);
  insert into public.kanban_write_requests(user_id, request_id, board_id, payload, saved_count)
    values (owner, public.skilltrack_receipt_key(operation, p_request_id), null,
      jsonb_build_object('request_id', p_request_id, 'board_id', board, 'request', payload, 'result', result), saved);
  return result;
end;
$$;

ALTER FUNCTION "public"."save_new_skilltrack_project"("p_request_id" "text", "p_name" "text", "p_description" "text", "p_constraints" "text", "p_start_date" "date", "p_end_date" "date", "p_tasks" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_replacement_task_drafts"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
declare
  receipt public.kanban_write_requests;
  draft jsonb;
  task_id uuid;
  next_order bigint;
  saved integer := 0;
  checklist jsonb;
  normalized_title text;
  project uuid;
  milestone jsonb;
  milestone_key text;
  milestone_uuid uuid;
  milestone_map jsonb := '{}'::jsonb;
  milestone_metadata jsonb := '{}'::jsonb;
  next_position integer;
  versioned_payload jsonb := jsonb_build_object('format', 'milestones-v1', 'tasks', p_tasks);
begin
  if auth.uid() is null or p_request_id is null
      or length(p_request_id) not between 16 and 128
      or jsonb_typeof(p_tasks) is distinct from 'array'
      or jsonb_array_length(p_tasks) not between 1 and 12 then
    raise exception 'Invalid generated task request' using errcode = '22023';
  end if;
  -- Serialize a request across boards as well as concurrent writers to a board.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_request_id, 0));
  perform public.assert_owned_kanban_board(p_board_id);
  select * into receipt from public.kanban_write_requests
    where user_id = auth.uid() and request_id = p_request_id;
  if found then
    if receipt.board_id <> p_board_id or receipt.payload <> versioned_payload then
      raise exception 'Request identifier already used for another payload' using errcode = '22023';
    end if;
    return receipt.saved_count;
  end if;
  select project_id into project from public.kanban_boards where id = p_board_id;
  -- Serialize milestone positions across boards of the same project.
  perform 1 from public.projects where id = project for update;
  select coalesce(max(position), -1) + 1 into next_position
    from public.project_milestones where project_id = project;
  select coalesce(max(sort_order), 0) into next_order
    from public.kanban_tasks where board_id = p_board_id
      and status = 'todo' and not is_archived;
  for draft in select value from jsonb_array_elements(p_tasks) loop
    checklist := coalesce(draft->'checklist', '[]'::jsonb);
    if jsonb_typeof(draft) is distinct from 'object'
        or jsonb_typeof(draft->'title') is distinct from 'string'
        or length(btrim(draft->>'title')) not between 1 and 150
        or jsonb_typeof(draft->'description') is distinct from 'string'
        or length(btrim(draft->>'description')) not between 1 and 1000
        or coalesce(draft->>'priority', '') not in ('low', 'medium', 'high')
        or coalesce(draft->>'deadline', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        or jsonb_typeof(checklist) is distinct from 'array' then
      raise exception 'Invalid generated task' using errcode = '22023';
    end if;
    -- Casting rejects invalid calendar dates; the transaction is rolled back.
    perform (draft->>'deadline')::date;
    if jsonb_array_length(checklist) > 5 or exists (
      select 1 from jsonb_array_elements(checklist) item
      where jsonb_typeof(item) <> 'string'
        or length(btrim(item #>> '{}')) not between 1 and 150
    ) or (select count(distinct lower(btrim(value #>> '{}')))
          from jsonb_array_elements(checklist)) <> jsonb_array_length(checklist) then
      raise exception 'Invalid generated checklist' using errcode = '22023';
    end if;
    milestone_uuid := null;
    milestone := draft->'milestone';
    if milestone is not null and milestone <> 'null'::jsonb then
      milestone_key := milestone->>'localId';
      if jsonb_typeof(milestone) is distinct from 'object'
          or coalesce(length(btrim(milestone_key)), 0) not between 1 and 128
          or jsonb_typeof(milestone->'title') is distinct from 'string'
          or length(btrim(milestone->>'title')) not between 1 and 150
          or coalesce(milestone->>'position', '') !~ '^[0-9]+$'
          or (milestone->>'position')::bigint > 2147483647 then
        raise exception 'Invalid milestone' using errcode = '22023';
      end if;
      if milestone_metadata ? milestone_key and milestone_metadata->milestone_key <> milestone then
        raise exception 'Inconsistent milestone identity' using errcode = '22023';
      end if;
      milestone_metadata := milestone_metadata || jsonb_build_object(milestone_key, milestone);
      if (select count(*) from jsonb_object_keys(milestone_metadata)) > 5 then
        raise exception 'Too many milestones' using errcode = '22023';
      end if;
      if nullif(milestone->>'existingMilestoneId', '') is not null then
        select id into milestone_uuid from public.project_milestones
          where id = (milestone->>'existingMilestoneId')::uuid and project_id = project;
        if not found then
          raise exception 'Milestone unavailable for this project' using errcode = '42501';
        end if;
      end if;
    end if;
    normalized_title := regexp_replace(lower(btrim(draft->>'title')), '[^[:alnum:]]+', ' ', 'g');
    -- Create only groups containing at least one new task, after duplicate validation.
    if milestone is not null and milestone <> 'null'::jsonb and milestone_uuid is null then
      milestone_uuid := (milestone_map->>milestone_key)::uuid;
      if milestone_uuid is null then
        select id into milestone_uuid from public.project_milestones
         where project_id=project and lower(btrim(title))=lower(btrim(milestone->>'title')) order by position,id limit 1;
      end if;
      if milestone_uuid is null then
        insert into public.project_milestones(project_id, title, position)
          values (project, btrim(milestone->>'title'), next_position)
          returning id into milestone_uuid;
        next_position := next_position + 1;
        milestone_map := milestone_map || jsonb_build_object(milestone_key, milestone_uuid);
      end if;
    end if;
    next_order := next_order + 1000;
    insert into public.kanban_tasks
      (board_id, title, description, priority, status, deadline, deadline_has_time, sort_order, is_archived, milestone_id)
    values (p_board_id, btrim(draft->>'title'), btrim(draft->>'description'),
      draft->>'priority', 'todo', (((draft->>'deadline')::date + time '23:59:00') at time zone 'Asia/Kuala_Lumpur'), false, next_order, false, milestone_uuid)
    returning id into task_id;
    insert into public.task_checklist_items (task_id, title, position, is_completed)
      select task_id, btrim(item.value #>> '{}'), (item.ordinality - 1)::integer, false
      from jsonb_array_elements(checklist) with ordinality item;
    insert into public.task_activity_logs (task_id, action, old_values, new_values)
      values (task_id, 'created', '{}'::jsonb, jsonb_build_object('title', draft->>'title'));
    saved := saved + 1;
  end loop;
  insert into public.kanban_write_requests (user_id, request_id, board_id, payload, saved_count)
    values (auth.uid(), p_request_id, p_board_id, versioned_payload, saved);
  return saved;
end;
$_$;

ALTER FUNCTION "public"."save_replacement_task_drafts"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_resource_analysis"("p_user_id" "uuid", "p_resource" "jsonb", "p_transcript" "jsonb", "p_keywords" "text"[], "p_topic_tags" "text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'storage', 'pg_temp'
    AS $$
declare
  resource public.learning_resources%rowtype;
  transcript public.video_transcripts%rowtype;
  saved public.resource_index%rowtype;
begin
  if p_user_id is null or p_resource is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  select * into resource from public.learning_resources
    where id=(p_resource->>'id')::uuid for update;
  if not found or resource.author_id<>p_user_id or resource.moderation_hidden
      or resource.status not in ('draft','published') then
    raise exception 'Resource analysis forbidden' using errcode='42501';
  end if;
  -- Compare all source fields, with timestamp normalization for REST encoding.
  if (to_jsonb(resource)-'created_at'-'updated_at') is distinct from
       (p_resource-'created_at'-'updated_at')
      or resource.updated_at is distinct from (p_resource->>'updated_at')::timestamptz
      or resource.created_at is distinct from (p_resource->>'created_at')::timestamptz then
    raise exception 'Resource changed' using errcode='40001';
  end if;
  if resource.kind='Video' or (public.is_pdf_resource(to_jsonb(resource)) or public.is_image_resource(to_jsonb(resource))) then
    if p_transcript is null then
      raise exception 'Current transcript required' using errcode='40001';
    end if;
    -- Block replacement while checking the current source and saving the index.
    perform 1 from storage.objects o where o.bucket_id=p_transcript->>'storage_bucket'
      and o.name=p_transcript->>'storage_path' for share;
    if not found then raise exception 'Video changed' using errcode='40001'; end if;
    select * into transcript from public.video_transcripts
      where id=(p_transcript->>'id')::uuid for share;
    if not found or transcript.status<>'ready'
      or transcript.transcript_text is distinct from coalesce(p_transcript->>'extracted_text',p_transcript->>'transcript_text')
      or not exists(select 1 from public.read_ready_resource_extraction(resource.id,
        resource.external_url,transcript.storage_bucket,transcript.storage_path) t
        where t.id=transcript.id and t.source_file_id=p_transcript->>'source_file_id'
          and t.source_version=p_transcript->>'source_version') then
      raise exception 'Video changed' using errcode='40001';
    end if;
  elsif p_transcript is not null then
    raise exception 'Resource kind changed' using errcode='40001';
  end if;
  if p_keywords is null or p_topic_tags is null
    or cardinality(p_keywords)>20 or cardinality(p_topic_tags)>8
    or exists(select 1 from unnest(p_keywords || p_topic_tags) x
      where x is null or length(btrim(x)) not between 1 and 80 or x ~ '[[:cntrl:]]') then
    raise exception 'Invalid resource analysis' using errcode='22023';
  end if;
  insert into public.resource_index(resource_id,keywords,topic_tags,analysed_at)
    values(resource.id,p_keywords,p_topic_tags,clock_timestamp())
  on conflict(resource_id) do update set keywords=excluded.keywords,
    topic_tags=excluded.topic_tags,analysed_at=excluded.analysed_at
  returning * into saved;
  return to_jsonb(saved);
end;
$$;

ALTER FUNCTION "public"."save_resource_analysis"("p_user_id" "uuid", "p_resource" "jsonb", "p_transcript" "jsonb", "p_keywords" "text"[], "p_topic_tags" "text"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."save_skilltrack_task_action"("p_board_id" "uuid", "p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    SET "TimeZone" TO 'UTC'
    AS $$
declare
  owner uuid := auth.uid();
  payload jsonb := jsonb_build_object('board_id', p_board_id, 'fields', p_payload);
  result jsonb;
  previous public.kanban_tasks;
  fields public.kanban_tasks;
  task_id_value uuid;
  now_at timestamptz;
  tag_ids uuid[];
  column_ids uuid[];
  column_orders bigint[];
  target_index integer;
  old_index integer;
  destination_order bigint;
  activity_action public.task_activity_logs.action%type;
begin
  if p_operation is null or p_operation not in ('create_task','move','archive','restore','resume')
      or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'Invalid task action' using errcode = '22023';
  end if;
  result := public.replay_skilltrack_write(p_operation, p_request_id, payload);
  if result is not null then return result; end if;

  if p_operation in ('archive', 'restore') then
    perform b.id from public.kanban_boards b join public.projects p on p.id = b.project_id
      where b.id = p_board_id and p.owner_id = owner for update of b;
    if not found then raise exception 'Project board unavailable' using errcode = '42501'; end if;
  else
    perform public.assert_owned_kanban_board(p_board_id);
  end if;

  if p_operation = 'create_task' then
    fields := jsonb_populate_record(null::public.kanban_tasks, p_payload);
    if coalesce(btrim(fields.title), '') = '' or fields.status is null
        or fields.status::text not in ('todo', 'in_progress', 'completed')
        or fields.priority is null or fields.priority::text not in ('low', 'medium', 'high')
        or jsonb_typeof(p_payload->'tag_ids') is distinct from 'array'
        or jsonb_typeof(p_payload->'checklist') is distinct from 'array'
        or exists (select 1 from jsonb_array_elements(p_payload->'checklist') e
          where jsonb_typeof(e) is distinct from 'string') then
      raise exception 'Invalid task fields' using errcode = '22023';
    end if;
    tag_ids := array(select distinct value::uuid from jsonb_array_elements_text(p_payload->'tag_ids'));
    if exists (select 1 from unnest(tag_ids) x(id)
      left join public.task_tags t on t.id = x.id and t.owner_id = owner where t.id is null) then
      raise exception 'Tag unavailable' using errcode = '42501';
    end if;
    select coalesce(max(t.sort_order), 0) + 1000 into destination_order from public.kanban_tasks t
      where t.board_id = p_board_id and t.status = fields.status and not coalesce(t.is_archived, false);
    now_at := clock_timestamp();
    insert into public.kanban_tasks(board_id, title, description, status, priority,
      deadline, deadline_has_time, milestone_id, sort_order, is_archived, completed_at,
      elapsed_seconds, tracking_started_at, created_at, updated_at)
    values (p_board_id, btrim(fields.title), coalesce(fields.description, ''), fields.status, fields.priority,
      fields.deadline, case when fields.deadline is not null then fields.deadline_has_time end,
      fields.milestone_id, destination_order, false, case when fields.status::text = 'completed' then now_at end,
      0, case when fields.status::text = 'in_progress' then now_at end, now_at, now_at)
    returning id into task_id_value;

    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      values (task_id_value, 'created', '{}'::jsonb, jsonb_build_object('title', btrim(fields.title)));
    insert into public.task_tag_links(task_id, tag_id) select task_id_value, id from unnest(tag_ids) x(id);
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      select task_id_value, 'tag_added', '{}'::jsonb, jsonb_build_object('tag_id', id) from unnest(tag_ids) x(id);
    with added as (
      insert into public.task_checklist_items(task_id, title, position, is_completed)
        select task_id_value, btrim(value), (ordinality - 1)::integer, false
        from jsonb_array_elements_text(p_payload->'checklist') with ordinality where btrim(value) <> ''
        returning id
    )
    insert into public.task_activity_logs(task_id, action, old_values, new_values)
      select task_id_value, 'checklist_updated', '{}'::jsonb, '{}'::jsonb from added;
  else
    task_id_value := (p_payload->>'task_id')::uuid;
    select * into previous from public.kanban_tasks t
      where t.id = task_id_value and t.board_id = p_board_id for update;
    if not found or (p_operation in ('move', 'resume') and coalesce(previous.is_archived, false)) then
      raise exception 'Task unavailable' using errcode = '42501';
    end if;
    if previous.updated_at is distinct from (p_payload->>'expected_updated_at')::timestamptz
        or (p_operation = 'move' and previous.sort_order is distinct from (p_payload->>'expected_sort_order')::bigint) then
      raise exception 'Task changed. Refresh it and try again.' using errcode = '40001';
    end if;

    if p_operation = 'move' then
      fields := jsonb_populate_record(null::public.kanban_tasks, p_payload);
      if fields.status is null or fields.status::text not in ('todo','in_progress','completed') then
        raise exception 'Invalid destination status' using errcode = '22023';
      end if;
      select array_agg(t.id order by t.sort_order, t.id), array_agg(t.sort_order order by t.sort_order, t.id)
        into column_ids, column_orders from public.kanban_tasks t
        where t.board_id = p_board_id and t.status = fields.status and t.id <> task_id_value
          and not coalesce(t.is_archived, false);
      target_index := least(greatest(coalesce((p_payload->>'new_index')::integer, cardinality(column_ids), 0), 0),
        coalesce(cardinality(column_ids), 0));
      select count(*) into old_index from public.kanban_tasks t
        where t.board_id = p_board_id and t.status = previous.status and not coalesce(t.is_archived, false)
        and (t.sort_order, t.id) < (previous.sort_order, previous.id);

      if previous.status is distinct from fields.status or old_index <> target_index then
        destination_order := case
          when coalesce(cardinality(column_ids), 0) = 0 then 1000
          when target_index = 0 and column_orders[1] > 1 then column_orders[1] / 2
          when target_index = cardinality(column_ids) then column_orders[target_index] + 1000
          when column_orders[target_index + 1] - column_orders[target_index] > 1
            then column_orders[target_index] + (column_orders[target_index + 1] - column_orders[target_index]) / 2
        end;
        if destination_order is null then
          destination_order := (target_index + 1) * 1000::bigint;
          update public.kanban_tasks t
            set sort_order = (x.ordinality + case when x.ordinality > target_index then 1 else 0 end) * 1000,
                updated_at = clock_timestamp()
            from unnest(column_ids) with ordinality x(id, ordinality)
            where t.id = x.id;
        end if;
        perform public.update_kanban_task_tracking(task_id_value, 'move', previous.updated_at,
          fields.status::text, destination_order);
        if previous.status is distinct from fields.status then
          activity_action := case when fields.status::text = 'completed' then 'completed'
            when previous.status::text = 'completed' then 'reopened' else 'moved' end;
          insert into public.task_activity_logs(task_id, action, old_values, new_values)
            values (task_id_value, activity_action,
              jsonb_build_object('status', previous.status, 'position', old_index),
              jsonb_build_object('status', fields.status, 'position', target_index));
        end if;
      end if;
    elsif p_operation = 'resume' then
      if previous.is_stalled then
        update public.kanban_tasks set is_stalled = false, stagnation_score = 0,
          stalled_at = null, updated_at = clock_timestamp() where id = task_id_value;
        insert into public.task_activity_logs(task_id, action, old_values, new_values)
          values (task_id_value, 'resumed', '{}'::jsonb, '{}'::jsonb);
      end if;
    elsif coalesce(previous.is_archived, false) <> (p_operation = 'archive') then
      now_at := clock_timestamp();
      -- Archiving settles an active session. Restoring leaves the timer paused.
      update public.kanban_tasks set is_archived = (p_operation = 'archive'), updated_at = now_at,
        elapsed_seconds = elapsed_seconds + case
          when p_operation = 'archive' and tracking_started_at is not null
          then greatest(0::bigint, floor(extract(epoch from (now_at - tracking_started_at)))::bigint)
          else 0 end,
        tracking_started_at = case when p_operation = 'archive' then null else tracking_started_at end
        where id = task_id_value;
      activity_action := case when p_operation = 'archive' then 'archived' else 'restored' end;
      insert into public.task_activity_logs(task_id, action, old_values, new_values)
        values (task_id_value, activity_action, '{}'::jsonb, '{}'::jsonb);
    end if;
  end if;

  select jsonb_build_object('task', to_jsonb(t)) into result
    from public.kanban_tasks t where t.id = task_id_value;
  insert into public.kanban_write_requests(user_id, request_id, board_id, payload, saved_count)
    values (owner, public.skilltrack_receipt_key(p_operation, p_request_id), null,
      jsonb_build_object('request_id', p_request_id, 'board_id', p_board_id, 'request', payload, 'result', result), 1);
  return result;
end;
$$;

ALTER FUNCTION "public"."save_skilltrack_task_action"("p_board_id" "uuid", "p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."set_task_resource_bookmark"("p_task_id" "uuid", "p_resource_id" "uuid", "p_saved" boolean) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if auth.uid() is null or not public.owns_bookmark_task(p_task_id) then
    raise exception 'Task access denied' using errcode='42501';
  end if;
  if p_saved is null or p_resource_id is null then raise exception 'Invalid bookmark' using errcode='22023'; end if;
  if p_saved then
    -- Existing saved pair is an idempotent success, even if access/status has
    -- changed since a lost response. No new content is exposed by this call.
    if exists(select 1 from public.task_resource_bookmarks where task_id=p_task_id and resource_id=p_resource_id) then return; end if;
    insert into public.task_resource_bookmarks(task_id,resource_id) values(p_task_id,p_resource_id)
      on conflict(task_id,resource_id) do nothing;
  else
    delete from public.task_resource_bookmarks where task_id=p_task_id and resource_id=p_resource_id;
  end if;
end $$;

ALTER FUNCTION "public"."set_task_resource_bookmark"("p_task_id" "uuid", "p_resource_id" "uuid", "p_saved" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."skilltrack_receipt_key"("p_operation" "text", "p_request_id" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO 'pg_catalog'
    AS $$
  select 'skilltrack:v1:' || p_operation || ':' || encode(sha256(convert_to(p_request_id, 'UTF8')), 'hex');
$$;

ALTER FUNCTION "public"."skilltrack_receipt_key"("p_operation" "text", "p_request_id" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."stalled_period_alert_state"("p_task_id" "uuid", "p_user_id" "uuid", "p_stalled_at" timestamp with time zone) RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select case when not exists(
    select 1 from public.kanban_tasks t join public.kanban_boards b on b.id=t.board_id
    join public.projects p on p.id=b.project_id join public.profiles pr on pr.id=p.owner_id
    where t.id=p_task_id and p.owner_id=p_user_id and p.status='active'
      and not b.is_archived and not t.is_archived and t.status<>'completed'
      and t.is_stalled and t.stalled_at=p_stalled_at
  ) then 'ineligible' when exists(
    select 1 from public.notifications n where n.user_id=p_user_id and n.task_id=p_task_id
      and n.type in ('STALLED_TASK','LEARNING_RESOURCE_RECOMMENDATION')
      and n.created_at>=p_stalled_at
  ) then 'handled' else 'eligible' end;
$$;

ALTER FUNCTION "public"."stalled_period_alert_state"("p_task_id" "uuid", "p_user_id" "uuid", "p_stalled_at" timestamp with time zone) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."task_list_replacement_context"("p_board_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare snapshot jsonb; version text; count_value integer;
begin
 perform public.assert_owned_kanban_board(p_board_id);
 select jsonb_build_object(
  'project', (select to_jsonb(p) from projects p join kanban_boards b on b.project_id=p.id where b.id=p_board_id),
  'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from kanban_tasks t where t.board_id=p_board_id),'[]'),
  'milestones', coalesce((select jsonb_agg(to_jsonb(m) order by m.id) from project_milestones m join kanban_boards b on b.project_id=m.project_id where b.id=p_board_id),'[]'),
  'checklists', coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from task_checklist_items c join kanban_tasks t on t.id=c.task_id where t.board_id=p_board_id),'[]')
 ) into snapshot;
 version:=encode(sha256(convert_to(snapshot::text,'UTF8')),'hex');
 select count(*) into count_value from kanban_tasks where board_id=p_board_id and not is_archived;
 return jsonb_build_object('version',version,'count',count_value);
end $$;

ALTER FUNCTION "public"."task_list_replacement_context"("p_board_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."task_recommendations"("p_task_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare result jsonb;
begin
 if auth.uid() is null or not public.owns_bookmark_task(p_task_id) then raise exception 'Task access denied' using errcode='42501'; end if;
 select jsonb_build_object('generated',s.generation_id is not null,'generation_id',s.generation_id,
   'generated_at',s.generated_at,'stalled_at',s.stalled_at,'recommendations',coalesce((
   select jsonb_agg(jsonb_build_object('resource_id',r.id,'title',r.title,'summary',coalesce(r.summary,''),'type',r.kind) order by i.position)
   from public.task_recommendation_items i join public.learning_resources r on r.id=i.resource_id
   where i.task_id=s.task_id and r.status='published' and not r.moderation_hidden),'[]'::jsonb)) into result
 from public.task_recommendation_sets s where s.task_id=p_task_id;
 return coalesce(result,'{"generated":false,"recommendations":[]}'::jsonb);
end $$;

ALTER FUNCTION "public"."task_recommendations"("p_task_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."task_saved_resources"("p_task_id" "uuid") RETURNS TABLE("resource_id" "uuid", "title" "text", "summary" "text", "type" "text")
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
begin
  if auth.uid() is null or not public.owns_bookmark_task(p_task_id) then
    raise exception 'Task access denied' using errcode='42501';
  end if;
  return query select saved.resource_id,
    coalesce(r.title,'Resource unavailable')::text,coalesce(r.summary,'')::text,coalesce(r.kind,'')::text
    from public.task_resource_bookmarks saved
    left join public.learning_resources r on r.id=saved.resource_id and r.status='published' and not r.moderation_hidden
    where saved.task_id=p_task_id order by saved.created_at,saved.resource_id;
end $$;

ALTER FUNCTION "public"."task_saved_resources"("p_task_id" "uuid") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."unregister_project_push_device"("p_fcm_token" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_fcm_token is null or length(btrim(p_fcm_token)) not between 1 and 4096 then
    raise exception 'Invalid push device registration' using errcode = '22023';
  end if;
  update public.project_push_devices set is_active = false
    where user_id = auth.uid() and fcm_token = p_fcm_token;
end;
$$;

ALTER FUNCTION "public"."unregister_project_push_device"("p_fcm_token" "text") OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."kanban_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "board_id" "uuid" NOT NULL,
    "title" character varying(200) NOT NULL,
    "description" "text",
    "status" character varying(20) DEFAULT 'todo'::character varying NOT NULL,
    "priority" character varying(10) DEFAULT 'medium'::character varying NOT NULL,
    "deadline" timestamp with time zone,
    "sort_order" numeric(20,10) DEFAULT 1000 NOT NULL,
    "completed_at" timestamp with time zone,
    "is_archived" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "stagnation_score" smallint DEFAULT 0 NOT NULL,
    "is_stalled" boolean DEFAULT false NOT NULL,
    "stalled_at" timestamp with time zone,
    "stagnation_checked_at" timestamp with time zone,
    "elapsed_seconds" bigint DEFAULT 0 NOT NULL,
    "tracking_started_at" timestamp with time zone,
    "milestone_id" "uuid",
    "deadline_has_time" boolean,
    CONSTRAINT "kanban_tasks_completion_valid" CHECK ((((("status")::"text" = 'completed'::"text") AND ("completed_at" IS NOT NULL)) OR ((("status")::"text" <> 'completed'::"text") AND ("completed_at" IS NULL)))),
    CONSTRAINT "kanban_tasks_elapsed_seconds_nonnegative" CHECK (("elapsed_seconds" >= 0)),
    CONSTRAINT "kanban_tasks_priority_valid" CHECK ((("priority")::"text" = ANY ((ARRAY['low'::character varying, 'medium'::character varying, 'high'::character varying])::"text"[]))),
    CONSTRAINT "kanban_tasks_sort_order_valid" CHECK (("sort_order" >= (0)::numeric)),
    CONSTRAINT "kanban_tasks_stagnation_score_check" CHECK ((("stagnation_score" >= 0) AND ("stagnation_score" <= 100))),
    CONSTRAINT "kanban_tasks_status_valid" CHECK ((("status")::"text" = ANY ((ARRAY['todo'::character varying, 'in_progress'::character varying, 'completed'::character varying])::"text"[]))),
    CONSTRAINT "kanban_tasks_title_not_blank" CHECK (("length"(TRIM(BOTH FROM "title")) > 0))
);

ALTER TABLE "public"."kanban_tasks" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_kanban_task_tracking"("p_task_id" "uuid", "p_action" "text", "p_expected_updated_at" timestamp with time zone, "p_status" "text" DEFAULT NULL::"text", "p_sort_order" bigint DEFAULT NULL::bigint) RETURNS "public"."kanban_tasks"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_task public.kanban_tasks%rowtype;
  v_status public.kanban_tasks.status%type;
  v_order public.kanban_tasks.sort_order%type;
  v_started_at timestamptz;
  v_completed_at public.kanban_tasks.completed_at%type;
  v_elapsed bigint;
  v_now timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Sign in to update task tracking'
      using errcode = '42501';
  end if;

  if p_task_id is null or p_expected_updated_at is null
      or p_action is null or p_action not in ('move', 'pause', 'resume') then
    raise exception 'Invalid task tracking request'
      using errcode = '22023';
  end if;

  if p_action = 'move' then
    if p_status is null or p_status not in ('todo', 'in_progress', 'completed') then
      raise exception 'Invalid destination status' using errcode = '22023';
    end if;
  elsif p_status is not null or p_sort_order is not null then
    raise exception 'Timer actions cannot change status or ordering'
      using errcode = '22023';
  end if;

  -- Serialize changes to this task; RLS still applies to every statement.
  select t.* into v_task
  from public.kanban_tasks t
  join public.kanban_boards b on b.id = t.board_id
  join public.projects p on p.id = b.project_id
  where t.id = p_task_id
    and p.owner_id = auth.uid()
    and p.status <> 'archived'
    and not coalesce(b.is_archived, false)
    and not coalesce(t.is_archived, false)
  for update of t;

  if not found then
    raise exception 'Task unavailable' using errcode = '42501';
  end if;

  -- Read time after obtaining the row lock, not at transaction start.
  v_now := clock_timestamp();
  v_status := v_task.status;
  v_order := v_task.sort_order;
  v_started_at := v_task.tracking_started_at;
  v_completed_at := v_task.completed_at;
  v_elapsed := v_task.elapsed_seconds;

  if p_action = 'move' then
    v_status := p_status;
    v_order := coalesce(p_sort_order, v_task.sort_order);

    if v_status is distinct from v_task.status then
      v_started_at := case when p_status = 'in_progress' then v_now else null end;
      v_completed_at := case when p_status = 'completed' then v_now else null end;
    end if;
  else
    if v_task.status::text <> 'in_progress' then
      raise exception 'Only In Progress tasks can be paused or resumed'
        using errcode = '22023';
    end if;

    if p_action = 'pause' then
      v_started_at := null;
    else
      -- A repeated resume preserves the original session start.
      v_started_at := coalesce(v_task.tracking_started_at, v_now);
    end if;
  end if;

  -- Repeated pause/resume and unchanged moves are harmless no-ops.
  if v_status is not distinct from v_task.status
      and v_order is not distinct from v_task.sort_order
      and v_started_at is not distinct from v_task.tracking_started_at
      and v_completed_at is not distinct from v_task.completed_at then
    return v_task;
  end if;

  -- Reject stale mutations, including delayed requests from another device.
  -- Flutter must refresh the task before retrying a conflict.
  if v_task.updated_at is distinct from p_expected_updated_at then
    raise exception 'Task changed. Refresh it and try again.'
      using errcode = '40001';
  end if;

  -- Settle a running session exactly once when it stops or changes status.
  if v_task.tracking_started_at is not null
      and v_started_at is distinct from v_task.tracking_started_at then
    v_elapsed := v_elapsed + greatest(
      0::bigint,
      floor(extract(epoch from (v_now - v_task.tracking_started_at)))::bigint
    );
  end if;

  update public.kanban_tasks
  set status = v_status,
      sort_order = v_order,
      completed_at = v_completed_at,
      elapsed_seconds = v_elapsed,
      tracking_started_at = v_started_at,
      updated_at = v_now
  where id = v_task.id
  returning * into v_task;

  return v_task;
end;
$$;

ALTER FUNCTION "public"."update_kanban_task_tracking"("p_task_id" "uuid", "p_action" "text", "p_expected_updated_at" timestamp with time zone, "p_status" "text", "p_sort_order" bigint) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."update_task_stagnation"("p_task_id" "uuid", "p_score" smallint, "p_checked_at" timestamp with time zone DEFAULT "now"()) RETURNS TABLE("became_stalled" boolean, "currently_stalled" boolean, "current_stalled_at" timestamp with time zone)
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
    previous_stalled boolean;
    next_stalled boolean;
    next_score smallint;
    next_stalled_at timestamptz;
    task_status text;
    task_archived boolean;
begin
    if p_score < 0 or p_score > 100 then
        raise exception 'Stagnation score must be between 0 and 100';
    end if;

    select
        t.is_stalled,
        t.status,
        coalesce(t.is_archived, false),
        t.stalled_at
    into
        previous_stalled,
        task_status,
        task_archived,
        next_stalled_at
    from public.kanban_tasks t
    where t.id = p_task_id
    for update;

    if not found then
        raise exception 'Task not found';
    end if;

    if task_status = 'completed' or task_archived then
        next_score := 0;
        next_stalled := false;
        next_stalled_at := null;
    else
        next_score := p_score;
        next_stalled := next_score >= 70;

        if next_stalled and not previous_stalled then
            next_stalled_at := p_checked_at;
        elsif not next_stalled then
            next_stalled_at := null;
        end if;
    end if;

    update public.kanban_tasks
    set
        stagnation_score = next_score,
        is_stalled = next_stalled,
        stalled_at = next_stalled_at,
        stagnation_checked_at = p_checked_at
    where id = p_task_id;

    return query
    select
        not previous_stalled and next_stalled,
        next_stalled,
        next_stalled_at;
end;
$$;

ALTER FUNCTION "public"."update_task_stagnation"("p_task_id" "uuid", "p_score" smallint, "p_checked_at" timestamp with time zone) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."video_transcription_candidates"("p_limit" integer DEFAULT 25, "p_after_id" "uuid" DEFAULT NULL::"uuid", "p_draft_resource_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "external_url" "text")
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'Invalid discovery batch size' using errcode = '22023';
  end if;
  return query
    select r.id, r.external_url from public.learning_resources r
    where r.kind = 'Video' and r.moderation_hidden = false
      and r.external_url is not null
      and ((p_draft_resource_id is null and r.status = 'published'
            and (p_after_id is null or r.id > p_after_id))
        or (p_draft_resource_id is not null and r.id = p_draft_resource_id
            and r.status = 'draft'))
    order by r.id limit p_limit;
end;
$$;

ALTER FUNCTION "public"."video_transcription_candidates"("p_limit" integer, "p_after_id" "uuid", "p_draft_resource_id" "uuid") OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."kanban_boards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "name" character varying(100) DEFAULT 'Kanban Board'::character varying NOT NULL,
    "description" "text",
    "is_archived" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kanban_boards_name_not_blank" CHECK (("length"(TRIM(BOTH FROM "name")) > 0))
);

ALTER TABLE "public"."kanban_boards" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."kanban_write_requests" (
    "user_id" "uuid" NOT NULL,
    "request_id" "text" NOT NULL,
    "board_id" "uuid",
    "payload" "jsonb" NOT NULL,
    "saved_count" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kanban_write_requests_receipt_scope_check" CHECK ((("board_id" IS NULL) = ("request_id" ~~ 'skilltrack:v1:%'::"text"))),
    CONSTRAINT "kanban_write_requests_request_id_check" CHECK ((("length"("request_id") >= 16) AND ("length"("request_id") <= 128)))
);

ALTER TABLE "public"."kanban_write_requests" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."notification_preferences" (
    "user_id" "uuid" NOT NULL,
    "stalled_task_enabled" boolean DEFAULT true NOT NULL,
    "deadline_reminder_enabled" boolean DEFAULT true NOT NULL,
    "recommendation_enabled" boolean DEFAULT true NOT NULL,
    "push_notifications_enabled" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "push_enabled" boolean DEFAULT false NOT NULL
);

ALTER TABLE "public"."notification_preferences" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" character varying(50) NOT NULL,
    "context_type" character varying(20) NOT NULL,
    "project_id" "uuid",
    "board_id" "uuid",
    "task_id" "uuid",
    "title" character varying(150) NOT NULL,
    "message" "text" NOT NULL,
    "is_read" boolean DEFAULT false NOT NULL,
    "read_at" timestamp with time zone,
    "action_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "unique_key" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "notification_context_matches_type" CHECK ((((("type")::"text" = 'STALLED_TASK'::"text") AND (("context_type")::"text" = 'TASK'::"text")) OR ((("type")::"text" = 'DEADLINE_REMINDER'::"text") AND (("context_type")::"text" = ANY ((ARRAY['TASK'::character varying, 'PROJECT'::character varying])::"text"[]))) OR ((("type")::"text" = 'LEARNING_RESOURCE_RECOMMENDATION'::"text") AND (("context_type")::"text" = 'RECOMMENDATION'::"text")))),
    CONSTRAINT "notifications_context_reference_check" CHECK ((((("context_type")::"text" = 'PROJECT'::"text") AND ("project_id" IS NOT NULL)) OR ((("context_type")::"text" = ANY ((ARRAY['TASK'::character varying, 'RECOMMENDATION'::character varying])::"text"[])) AND ("project_id" IS NOT NULL) AND ("board_id" IS NOT NULL) AND ("task_id" IS NOT NULL)))),
    CONSTRAINT "notifications_context_valid" CHECK ((("context_type")::"text" = ANY ((ARRAY['TASK'::character varying, 'PROJECT'::character varying, 'RECOMMENDATION'::character varying])::"text"[]))),
    CONSTRAINT "notifications_read_state_check" CHECK (((("is_read" = false) AND ("read_at" IS NULL)) OR (("is_read" = true) AND ("read_at" IS NOT NULL)))),
    CONSTRAINT "notifications_type_valid" CHECK ((("type")::"text" = ANY ((ARRAY['STALLED_TASK'::character varying, 'DEADLINE_REMINDER'::character varying, 'LEARNING_RESOURCE_RECOMMENDATION'::character varying])::"text"[])))
);

ALTER TABLE "public"."notifications" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."project_push_devices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "fcm_token" "text" NOT NULL,
    "platform" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "project_push_devices_fcm_token_check" CHECK ((("length"("btrim"("fcm_token")) >= 1) AND ("length"("btrim"("fcm_token")) <= 4096))),
    CONSTRAINT "project_push_devices_platform_check" CHECK (("platform" = ANY (ARRAY['android'::"text", 'ios'::"text"])))
);

ALTER TABLE "public"."project_push_devices" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."projects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "name" character varying(150) NOT NULL,
    "description" "text",
    "status" character varying(20) DEFAULT 'active'::character varying NOT NULL,
    "start_date" "date",
    "end_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "constraints_text" "text",
    CONSTRAINT "projects_date_range_valid" CHECK ((("start_date" IS NULL) OR ("end_date" IS NULL) OR ("end_date" >= "start_date"))),
    CONSTRAINT "projects_name_not_blank" CHECK (("length"(TRIM(BOTH FROM "name")) > 0)),
    CONSTRAINT "projects_status_valid" CHECK ((("status")::"text" = ANY ((ARRAY['active'::character varying, 'completed'::character varying, 'archived'::character varying])::"text"[])))
);

ALTER TABLE "public"."projects" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."resource_analysis_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "resource_id" "uuid" NOT NULL,
    "transcript_id" "uuid",
    "source_file_id" "text",
    "source_version" "text",
    "allow_draft" boolean DEFAULT false NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "claim_token" "uuid",
    "lease_expires_at" timestamp with time zone,
    "next_attempt_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "error_code" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "content_version" "text" NOT NULL,
    CONSTRAINT "resource_analysis_jobs_attempt_count_check" CHECK (("attempt_count" >= 0)),
    CONSTRAINT "resource_analysis_jobs_check" CHECK ((("status" = 'processing'::"text") = ("lease_expires_at" IS NOT NULL))),
    CONSTRAINT "resource_analysis_jobs_check1" CHECK ((("status" <> 'processing'::"text") OR ("claim_token" IS NOT NULL))),
    CONSTRAINT "resource_analysis_jobs_source_check" CHECK (((("transcript_id" IS NULL) AND ("source_file_id" IS NULL) AND ("source_version" IS NULL)) OR (("transcript_id" IS NOT NULL) AND ("source_file_id" IS NOT NULL) AND ("source_version" IS NOT NULL)))),
    CONSTRAINT "resource_analysis_jobs_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'processing'::"text", 'ready'::"text", 'failed'::"text", 'skipped'::"text"])))
);

ALTER TABLE "public"."resource_analysis_jobs" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."resource_index" (
    "resource_id" "uuid" NOT NULL,
    "keywords" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "topic_tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "analysed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."resource_index" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."recommendation_index_sources" AS
 SELECT "r"."id" AS "resource_id",
    "r"."title",
    "r"."summary",
    "concat_ws"(' '::"text",
        CASE
            WHEN "public"."is_image_resource"("to_jsonb"("r".*)) THEN "t"."transcript_text"
            ELSE NULL::"text"
        END, "r"."summary", "r"."category") AS "description",
    "r"."kind" AS "resource_type",
        CASE
            WHEN "public"."is_pdf_resource"("to_jsonb"("r".*)) THEN "t"."transcript_text"
            ELSE "r"."body"
        END AS "pdf_text",
        CASE
            WHEN ("r"."kind" = 'Video'::"text") THEN COALESCE("t"."transcript_text", ''::"text")
            ELSE ''::"text"
        END AS "transcript",
    "i"."keywords",
    "i"."topic_tags",
    "r"."updated_at" AS "resource_updated_at",
    "encode"("sha256"("convert_to"(("jsonb_build_array"("c"."content_version", "i"."keywords", "i"."topic_tags"))::"text", 'UTF8'::"name")), 'hex'::"text") AS "source_version"
   FROM (((("public"."learning_resources" "r"
     JOIN "public"."resource_analysis_candidates"(NULL::"uuid", false) "c"("resource_id", "transcript_id", "source_file_id", "source_version", "content_version") ON (("c"."resource_id" = "r"."id")))
     JOIN "public"."resource_index" "i" ON (("i"."resource_id" = "r"."id")))
     JOIN "public"."resource_analysis_jobs" "j" ON ((("j"."resource_id" = "r"."id") AND ("j"."content_version" = "c"."content_version") AND ("j"."status" = 'ready'::"text") AND ("j"."updated_at" >= "i"."analysed_at"))))
     LEFT JOIN "public"."video_transcripts" "t" ON (("t"."id" = "c"."transcript_id")))
  WHERE (("r"."status" = 'published'::"text") AND ("r"."moderation_hidden" = false));

ALTER VIEW "public"."recommendation_index_sources" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."resource_embeddings" (
    "resource_id" "uuid" NOT NULL,
    "source_version" "text" NOT NULL,
    "indexed_version" "text",
    "embedding" "extensions"."vector"(384),
    "model_id" "text" DEFAULT 'gte-small'::"text" NOT NULL,
    "text_version" "text" DEFAULT 'skilltrack-v1-chunk400-mean-l2'::"text" NOT NULL,
    "keywords" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "topic_tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "domains" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "frameworks" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "claim_token" "uuid",
    "lease_expires_at" timestamp with time zone,
    "next_attempt_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "error_code" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "resource_embeddings_attempt_count_check" CHECK (("attempt_count" >= 0)),
    CONSTRAINT "resource_embeddings_check" CHECK ((("status" = 'processing'::"text") = ("lease_expires_at" IS NOT NULL))),
    CONSTRAINT "resource_embeddings_check1" CHECK ((("status" <> 'processing'::"text") OR ("claim_token" IS NOT NULL))),
    CONSTRAINT "resource_embeddings_check2" CHECK ((("status" <> 'ready'::"text") OR (("embedding" IS NOT NULL) AND ("indexed_version" = "source_version")))),
    CONSTRAINT "resource_embeddings_embedding_check" CHECK ((("embedding" IS NULL) OR ("extensions"."vector_norm"("embedding") > (0)::double precision))),
    CONSTRAINT "resource_embeddings_model_id_check" CHECK (("model_id" = 'gte-small'::"text")),
    CONSTRAINT "resource_embeddings_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'processing'::"text", 'ready'::"text", 'failed'::"text", 'skipped'::"text"]))),
    CONSTRAINT "resource_embeddings_text_version_check" CHECK (("text_version" = 'skilltrack-v1-chunk400-mean-l2'::"text"))
);

ALTER TABLE "public"."resource_embeddings" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."task_activity_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "action" character varying(30) NOT NULL,
    "old_values" "jsonb",
    "new_values" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "task_activity_action_valid" CHECK ((("action")::"text" = ANY ((ARRAY['created'::character varying, 'updated'::character varying, 'moved'::character varying, 'completed'::character varying, 'reopened'::character varying, 'archived'::character varying, 'restored'::character varying, 'resumed'::character varying, 'tag_added'::character varying, 'tag_removed'::character varying, 'checklist_updated'::character varying, 'attachment_added'::character varying, 'attachment_removed'::character varying])::"text"[])))
);

ALTER TABLE "public"."task_activity_logs" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."task_attachment_cleanup" (
    "user_id" "uuid" NOT NULL,
    "storage_path" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "task_attachment_cleanup_check" CHECK (("split_part"("storage_path", '/'::"text", 1) = ("user_id")::"text"))
);

ALTER TABLE "public"."task_attachment_cleanup" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."task_checklist_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "title" character varying(300) NOT NULL,
    "is_completed" boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "checklist_completion_valid" CHECK (((("is_completed" = true) AND ("completed_at" IS NOT NULL)) OR (("is_completed" = false) AND ("completed_at" IS NULL)))),
    CONSTRAINT "checklist_position_valid" CHECK (("position" >= 0)),
    CONSTRAINT "checklist_title_not_blank" CHECK (("length"(TRIM(BOTH FROM "title")) > 0))
);

ALTER TABLE "public"."task_checklist_items" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."task_recommendation_items" (
    "task_id" "uuid" NOT NULL,
    "resource_id" "uuid" NOT NULL,
    "position" integer NOT NULL,
    "source_version" "text" NOT NULL,
    CONSTRAINT "task_recommendation_items_position_check" CHECK ((("position" >= 0) AND ("position" <= 2)))
);

ALTER TABLE "public"."task_recommendation_items" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."task_recommendation_sets" (
    "task_id" "uuid" NOT NULL,
    "generation_id" "uuid",
    "generated_at" timestamp with time zone,
    "task_version" "text",
    "stalled_at" timestamp with time zone,
    "model_id" "text",
    "text_version" "text",
    "claim_token" "uuid",
    "claim_version" "text",
    "claim_mode" "text",
    "lease_expires_at" timestamp with time zone
);

ALTER TABLE "public"."task_recommendation_sets" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."task_resource_bookmarks" (
    "task_id" "uuid" NOT NULL,
    "resource_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."task_resource_bookmarks" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."task_tag_links" (
    "task_id" "uuid" NOT NULL,
    "tag_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."task_tag_links" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."task_tags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "name" character varying(50) NOT NULL,
    "color_hex" character(7),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "task_tags_color_valid" CHECK ((("color_hex" IS NULL) OR ("color_hex" ~ '^#[0-9A-Fa-f]{6}$'::"text"))),
    CONSTRAINT "task_tags_name_not_blank" CHECK (("length"(TRIM(BOTH FROM "name")) > 0))
);

ALTER TABLE "public"."task_tags" OWNER TO "postgres";

ALTER TABLE ONLY "public"."kanban_boards"
    ADD CONSTRAINT "kanban_boards_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."kanban_boards"
    ADD CONSTRAINT "kanban_boards_project_id_key" UNIQUE ("project_id");

ALTER TABLE ONLY "public"."kanban_tasks"
    ADD CONSTRAINT "kanban_tasks_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."kanban_write_requests"
    ADD CONSTRAINT "kanban_write_requests_pkey" PRIMARY KEY ("user_id", "request_id");

ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_pkey" PRIMARY KEY ("user_id");

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_milestones"
    ADD CONSTRAINT "project_milestones_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_push_devices"
    ADD CONSTRAINT "project_push_devices_fcm_token_key" UNIQUE ("fcm_token");

ALTER TABLE ONLY "public"."project_push_devices"
    ADD CONSTRAINT "project_push_devices_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."resource_analysis_jobs"
    ADD CONSTRAINT "resource_analysis_jobs_content_unique" UNIQUE ("resource_id", "content_version");

ALTER TABLE ONLY "public"."resource_analysis_jobs"
    ADD CONSTRAINT "resource_analysis_jobs_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."resource_embeddings"
    ADD CONSTRAINT "resource_embeddings_pkey" PRIMARY KEY ("resource_id");

ALTER TABLE ONLY "public"."resource_index"
    ADD CONSTRAINT "resource_index_pkey" PRIMARY KEY ("resource_id");

ALTER TABLE ONLY "public"."task_activity_logs"
    ADD CONSTRAINT "task_activity_logs_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."task_attachment_cleanup"
    ADD CONSTRAINT "task_attachment_cleanup_pkey" PRIMARY KEY ("user_id", "storage_path");

ALTER TABLE ONLY "public"."task_attachments"
    ADD CONSTRAINT "task_attachments_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."task_checklist_items"
    ADD CONSTRAINT "task_checklist_items_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."task_recommendation_items"
    ADD CONSTRAINT "task_recommendation_items_pkey" PRIMARY KEY ("task_id", "resource_id");

ALTER TABLE ONLY "public"."task_recommendation_items"
    ADD CONSTRAINT "task_recommendation_items_task_id_position_key" UNIQUE ("task_id", "position");

ALTER TABLE ONLY "public"."task_recommendation_sets"
    ADD CONSTRAINT "task_recommendation_sets_pkey" PRIMARY KEY ("task_id");

ALTER TABLE ONLY "public"."task_resource_bookmarks"
    ADD CONSTRAINT "task_resource_bookmarks_pkey" PRIMARY KEY ("task_id", "resource_id");

ALTER TABLE ONLY "public"."task_tag_links"
    ADD CONSTRAINT "task_tag_links_pkey" PRIMARY KEY ("task_id", "tag_id");

ALTER TABLE ONLY "public"."task_tags"
    ADD CONSTRAINT "task_tags_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."task_checklist_items"
    ADD CONSTRAINT "uq_checklist_task_position" UNIQUE ("task_id", "position");

ALTER TABLE ONLY "public"."resource_extractions"
    ADD CONSTRAINT "video_transcripts_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."resource_extractions"
    ADD CONSTRAINT "video_transcripts_resource_id_source_file_id_source_version_key" UNIQUE ("resource_id", "source_file_id", "source_version");

CREATE INDEX "idx_checklist_items_task_completed" ON "public"."task_checklist_items" USING "btree" ("task_id", "is_completed");

CREATE INDEX "idx_checklist_items_task_id" ON "public"."task_checklist_items" USING "btree" ("task_id");

CREATE INDEX "idx_kanban_boards_project_active" ON "public"."kanban_boards" USING "btree" ("project_id", "is_archived");

CREATE INDEX "idx_kanban_tasks_board_active_status" ON "public"."kanban_tasks" USING "btree" ("board_id", "is_archived", "status");

CREATE INDEX "idx_kanban_tasks_board_id" ON "public"."kanban_tasks" USING "btree" ("board_id");

CREATE INDEX "idx_kanban_tasks_board_status_order" ON "public"."kanban_tasks" USING "btree" ("board_id", "status", "sort_order");

CREATE INDEX "idx_kanban_tasks_created_at" ON "public"."kanban_tasks" USING "btree" ("created_at" DESC);

CREATE INDEX "idx_kanban_tasks_deadline" ON "public"."kanban_tasks" USING "btree" ("deadline");

CREATE INDEX "idx_kanban_tasks_priority" ON "public"."kanban_tasks" USING "btree" ("priority");

CREATE INDEX "idx_notifications_project" ON "public"."notifications" USING "btree" ("project_id");

CREATE INDEX "idx_notifications_task" ON "public"."notifications" USING "btree" ("task_id");

CREATE INDEX "idx_notifications_user_created" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);

CREATE INDEX "idx_notifications_user_unread" ON "public"."notifications" USING "btree" ("user_id", "is_read", "created_at" DESC);

CREATE INDEX "idx_projects_created_at" ON "public"."projects" USING "btree" ("created_at" DESC);

CREATE INDEX "idx_projects_owner_id" ON "public"."projects" USING "btree" ("owner_id");

CREATE INDEX "idx_projects_owner_status" ON "public"."projects" USING "btree" ("owner_id", "status");

CREATE INDEX "idx_task_activity_logs_action" ON "public"."task_activity_logs" USING "btree" ("action");

CREATE INDEX "idx_task_activity_logs_task_created" ON "public"."task_activity_logs" USING "btree" ("task_id", "created_at" DESC);

CREATE INDEX "idx_task_activity_logs_task_id" ON "public"."task_activity_logs" USING "btree" ("task_id");

CREATE INDEX "idx_task_attachments_task_created" ON "public"."task_attachments" USING "btree" ("task_id", "created_at" DESC);

CREATE INDEX "idx_task_attachments_task_id" ON "public"."task_attachments" USING "btree" ("task_id");

CREATE INDEX "idx_task_tag_links_tag_id" ON "public"."task_tag_links" USING "btree" ("tag_id");

CREATE INDEX "idx_task_tag_links_task_id" ON "public"."task_tag_links" USING "btree" ("task_id");

CREATE INDEX "idx_task_tags_owner_id" ON "public"."task_tags" USING "btree" ("owner_id");

CREATE INDEX "kanban_tasks_milestone_idx" ON "public"."kanban_tasks" USING "btree" ("milestone_id");

CREATE INDEX "kanban_tasks_stalled_idx" ON "public"."kanban_tasks" USING "btree" ("board_id", "is_stalled") WHERE ("is_stalled" = true);

CREATE INDEX "notification_activity_latest_idx" ON "public"."task_activity_logs" USING "btree" ("task_id", "created_at" DESC);

CREATE INDEX "notifications_project_id_idx" ON "public"."notifications" USING "btree" ("project_id") WHERE ("project_id" IS NOT NULL);

CREATE INDEX "notifications_task_id_idx" ON "public"."notifications" USING "btree" ("task_id") WHERE ("task_id" IS NOT NULL);

CREATE INDEX "notifications_user_created_at_idx" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);

CREATE INDEX "notifications_user_type_idx" ON "public"."notifications" USING "btree" ("user_id", "type", "created_at" DESC);

CREATE UNIQUE INDEX "notifications_user_unique_key_idx" ON "public"."notifications" USING "btree" ("user_id", "unique_key") WHERE ("unique_key" IS NOT NULL);

CREATE INDEX "notifications_user_unread_idx" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC) WHERE ("is_read" = false);

CREATE INDEX "project_milestones_project_position_idx" ON "public"."project_milestones" USING "btree" ("project_id", "position", "id");

CREATE INDEX "project_push_devices_active_user_idx" ON "public"."project_push_devices" USING "btree" ("user_id") WHERE "is_active";

CREATE INDEX "resource_analysis_jobs_claim_idx" ON "public"."resource_analysis_jobs" USING "btree" ("status", "next_attempt_at", "lease_expires_at", "created_at");

CREATE INDEX "resource_embeddings_pending" ON "public"."resource_embeddings" USING "btree" ("status", "next_attempt_at", "lease_expires_at");

CREATE INDEX "resource_index_keywords_gin" ON "public"."resource_index" USING "gin" ("keywords");

CREATE INDEX "resource_index_topic_tags_gin" ON "public"."resource_index" USING "gin" ("topic_tags");

CREATE INDEX "task_recommendation_resource_idx" ON "public"."task_recommendation_items" USING "btree" ("resource_id");

CREATE INDEX "task_resource_bookmarks_resource_idx" ON "public"."task_resource_bookmarks" USING "btree" ("resource_id");

CREATE UNIQUE INDEX "uq_notifications_unique_key" ON "public"."notifications" USING "btree" ("user_id", "unique_key") WHERE ("unique_key" IS NOT NULL);

CREATE UNIQUE INDEX "uq_task_tags_owner_name" ON "public"."task_tags" USING "btree" ("owner_id", "lower"(("name")::"text"));

CREATE INDEX "video_transcripts_claim_idx" ON "public"."resource_extractions" USING "btree" ("status", "next_attempt_at", "lease_expires_at", "created_at");

CREATE OR REPLACE TRIGGER "kanban_boards_keep_milestone_project" BEFORE UPDATE OF "project_id" ON "public"."kanban_boards" FOR EACH ROW EXECUTE FUNCTION "public"."keep_board_milestone_project"();

CREATE OR REPLACE TRIGGER "kanban_tasks_milestone_project" BEFORE INSERT OR UPDATE OF "milestone_id", "board_id" ON "public"."kanban_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."check_task_milestone_project"();

CREATE OR REPLACE TRIGGER "notification_preferences_timestamp" BEFORE UPDATE ON "public"."notification_preferences" FOR EACH ROW EXECUTE FUNCTION "public"."notification_preferences_timestamp"();

CREATE OR REPLACE TRIGGER "notification_read_only_update" BEFORE UPDATE ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "public"."notification_read_only_update"();

-- Database Webhooks are optional on a fresh Supabase project.
DO $optional_push_webhook$
BEGIN
  IF to_regprocedure('supabase_functions.http_request()') IS NOT NULL THEN
    EXECUTE $create_push_trigger$CREATE OR REPLACE TRIGGER "project-push-notification-dispatcher"
AFTER INSERT ON "public"."notifications" FOR EACH ROW
EXECUTE FUNCTION "supabase_functions"."http_request"(
  'https://TARGET_PROJECT_REF.supabase.co/functions/v1/project-push-notification-dispatcher',
  'POST', '{"Content-Type":"application/json","x-project-push-secret":"CONFIGURE_TARGET_SECRET"}', '{}', '30000')$create_push_trigger$;
    EXECUTE 'ALTER TABLE public.notifications DISABLE TRIGGER "project-push-notification-dispatcher"';
  ELSE
    RAISE NOTICE 'Push dispatcher deferred: enable Database Webhooks and configure the target endpoint/secret before installing it.';
  END IF;
END;
$optional_push_webhook$;

CREATE OR REPLACE TRIGGER "project_milestones_keep_project" BEFORE UPDATE OF "project_id" ON "public"."project_milestones" FOR EACH ROW EXECUTE FUNCTION "public"."keep_milestone_project"();

CREATE OR REPLACE TRIGGER "project_push_device_timestamp" BEFORE UPDATE ON "public"."project_push_devices" FOR EACH ROW EXECUTE FUNCTION "public"."notification_preferences_timestamp"();

CREATE OR REPLACE TRIGGER "queue_deleted_task_attachment" AFTER DELETE ON "public"."task_attachments" FOR EACH ROW EXECUTE FUNCTION "public"."queue_deleted_task_attachment"();

CREATE OR REPLACE TRIGGER "resource_analysis_ready_embedding" AFTER INSERT OR UPDATE OF "status" ON "public"."resource_analysis_jobs" FOR EACH ROW EXECUTE FUNCTION "public"."queue_resource_embedding_after_analysis"();

CREATE OR REPLACE TRIGGER "saved_resource_analysis" AFTER INSERT OR UPDATE ON "public"."learning_resources" FOR EACH ROW EXECUTE FUNCTION "public"."queue_saved_resource_analysis"();

CREATE OR REPLACE TRIGGER "video_transcript_ready_analysis" AFTER INSERT OR UPDATE OF "status" ON "public"."resource_extractions" FOR EACH ROW EXECUTE FUNCTION "public"."queue_ready_transcript_analysis"();

ALTER TABLE ONLY "public"."kanban_boards"
    ADD CONSTRAINT "kanban_boards_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."kanban_tasks"
    ADD CONSTRAINT "kanban_tasks_board_id_fkey" FOREIGN KEY ("board_id") REFERENCES "public"."kanban_boards"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."kanban_tasks"
    ADD CONSTRAINT "kanban_tasks_milestone_id_fkey" FOREIGN KEY ("milestone_id") REFERENCES "public"."project_milestones"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."kanban_write_requests"
    ADD CONSTRAINT "kanban_write_requests_board_id_fkey" FOREIGN KEY ("board_id") REFERENCES "public"."kanban_boards"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."kanban_write_requests"
    ADD CONSTRAINT "kanban_write_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_board_id_fkey" FOREIGN KEY ("board_id") REFERENCES "public"."kanban_boards"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."kanban_tasks"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_milestones"
    ADD CONSTRAINT "project_milestones_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_push_devices"
    ADD CONSTRAINT "project_push_devices_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."resource_analysis_jobs"
    ADD CONSTRAINT "resource_analysis_jobs_resource_id_fkey" FOREIGN KEY ("resource_id") REFERENCES "public"."learning_resources"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."resource_analysis_jobs"
    ADD CONSTRAINT "resource_analysis_jobs_transcript_id_fkey" FOREIGN KEY ("transcript_id") REFERENCES "public"."resource_extractions"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."resource_embeddings"
    ADD CONSTRAINT "resource_embeddings_resource_id_fkey" FOREIGN KEY ("resource_id") REFERENCES "public"."learning_resources"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."resource_index"
    ADD CONSTRAINT "resource_index_resource_id_fkey" FOREIGN KEY ("resource_id") REFERENCES "public"."learning_resources"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_activity_logs"
    ADD CONSTRAINT "task_activity_logs_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."kanban_tasks"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_attachment_cleanup"
    ADD CONSTRAINT "task_attachment_cleanup_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_attachments"
    ADD CONSTRAINT "task_attachments_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."kanban_tasks"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_checklist_items"
    ADD CONSTRAINT "task_checklist_items_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."kanban_tasks"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_recommendation_items"
    ADD CONSTRAINT "task_recommendation_items_resource_id_fkey" FOREIGN KEY ("resource_id") REFERENCES "public"."learning_resources"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_recommendation_items"
    ADD CONSTRAINT "task_recommendation_items_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."task_recommendation_sets"("task_id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_recommendation_sets"
    ADD CONSTRAINT "task_recommendation_sets_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."kanban_tasks"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_resource_bookmarks"
    ADD CONSTRAINT "task_resource_bookmarks_resource_id_fkey" FOREIGN KEY ("resource_id") REFERENCES "public"."learning_resources"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_resource_bookmarks"
    ADD CONSTRAINT "task_resource_bookmarks_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."kanban_tasks"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_tag_links"
    ADD CONSTRAINT "task_tag_links_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."task_tags"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_tag_links"
    ADD CONSTRAINT "task_tag_links_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."kanban_tasks"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."task_tags"
    ADD CONSTRAINT "task_tags_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

CREATE POLICY "Users can add own tags to own tasks" ON "public"."task_tag_links" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM ((("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
     JOIN "public"."task_tags" ON (("task_tags"."id" = "task_tag_links"."tag_id")))
  WHERE (("kanban_tasks"."id" = "task_tag_links"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("task_tags"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can create boards for own projects" ON "public"."kanban_boards" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."projects"
  WHERE (("projects"."id" = "kanban_boards"."project_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can create own attachment metadata" ON "public"."task_attachments" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_attachments"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can create own checklist items" ON "public"."task_checklist_items" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_checklist_items"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can create own notification preferences" ON "public"."notification_preferences" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can create own notifications" ON "public"."notifications" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can create own projects" ON "public"."projects" FOR INSERT TO "authenticated" WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Users can create own tags" ON "public"."task_tags" FOR INSERT TO "authenticated" WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Users can create own task activity" ON "public"."task_activity_logs" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_activity_logs"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can create tasks on own boards" ON "public"."kanban_tasks" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."kanban_boards"
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_boards"."id" = "kanban_tasks"."board_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can delete own attachment metadata" ON "public"."task_attachments" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_attachments"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can delete own boards" ON "public"."kanban_boards" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects"
  WHERE (("projects"."id" = "kanban_boards"."project_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can delete own checklist items" ON "public"."task_checklist_items" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_checklist_items"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can delete own projects" ON "public"."projects" FOR DELETE TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Users can delete own tags" ON "public"."task_tags" FOR DELETE TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Users can delete own tasks" ON "public"."kanban_tasks" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."kanban_boards"
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_boards"."id" = "kanban_tasks"."board_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can read own attachment metadata" ON "public"."task_attachments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_attachments"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can read own boards" ON "public"."kanban_boards" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects"
  WHERE (("projects"."id" = "kanban_boards"."project_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can read own checklist items" ON "public"."task_checklist_items" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_checklist_items"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can read own projects" ON "public"."projects" FOR SELECT TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Users can read own tags" ON "public"."task_tags" FOR SELECT TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Users can read own task activity" ON "public"."task_activity_logs" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_activity_logs"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can read own task tag links" ON "public"."task_tag_links" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ((("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
     JOIN "public"."task_tags" ON (("task_tags"."id" = "task_tag_links"."tag_id")))
  WHERE (("kanban_tasks"."id" = "task_tag_links"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("task_tags"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can read own tasks" ON "public"."kanban_tasks" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."kanban_boards"
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_boards"."id" = "kanban_tasks"."board_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can remove own task tag links" ON "public"."task_tag_links" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ((("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
     JOIN "public"."task_tags" ON (("task_tags"."id" = "task_tag_links"."tag_id")))
  WHERE (("kanban_tasks"."id" = "task_tag_links"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("task_tags"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can update own boards" ON "public"."kanban_boards" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects"
  WHERE (("projects"."id" = "kanban_boards"."project_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."projects"
  WHERE (("projects"."id" = "kanban_boards"."project_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can update own checklist items" ON "public"."task_checklist_items" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_checklist_items"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."kanban_tasks"
     JOIN "public"."kanban_boards" ON (("kanban_boards"."id" = "kanban_tasks"."board_id")))
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_tasks"."id" = "task_checklist_items"."task_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can update own notification preferences" ON "public"."notification_preferences" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can update own notifications" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can update own projects" ON "public"."projects" FOR UPDATE TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Users can update own tags" ON "public"."task_tags" FOR UPDATE TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "Users can update own tasks" ON "public"."kanban_tasks" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."kanban_boards"
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_boards"."id" = "kanban_tasks"."board_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."kanban_boards"
     JOIN "public"."projects" ON (("projects"."id" = "kanban_boards"."project_id")))
  WHERE (("kanban_boards"."id" = "kanban_tasks"."board_id") AND ("projects"."owner_id" = ( SELECT "auth"."uid"() AS "uid"))))));

CREATE POLICY "Users can view own notification preferences" ON "public"."notification_preferences" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can view own notifications" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "bookmark_add" ON "public"."task_resource_bookmarks" FOR INSERT TO "authenticated" WITH CHECK (("public"."owns_bookmark_task"("task_id", true) AND (EXISTS ( SELECT 1
   FROM "public"."learning_resources" "r"
  WHERE (("r"."id" = "task_resource_bookmarks"."resource_id") AND ("r"."status" = 'published'::"text") AND (NOT "r"."moderation_hidden"))))));

CREATE POLICY "bookmark_read" ON "public"."task_resource_bookmarks" FOR SELECT TO "authenticated" USING ("public"."owns_bookmark_task"("task_id"));

CREATE POLICY "bookmark_remove" ON "public"."task_resource_bookmarks" FOR DELETE TO "authenticated" USING ("public"."owns_bookmark_task"("task_id"));

ALTER TABLE "public"."kanban_boards" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."kanban_tasks" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."kanban_write_requests" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "kanban_write_requests_check_durable_board" ON "public"."kanban_write_requests" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((("board_id" IS NOT NULL) OR ("request_id" ~~ 'skilltrack:v1:attachment_cleanup:%'::"text") OR (EXISTS ( SELECT 1
   FROM ("public"."kanban_boards" "b"
     JOIN "public"."projects" "p" ON (("p"."id" = "b"."project_id")))
  WHERE (("b"."id" = (("kanban_write_requests"."payload" ->> 'board_id'::"text"))::"uuid") AND ("p"."owner_id" = "auth"."uid"()))))));

CREATE POLICY "kanban_write_requests_insert" ON "public"."kanban_write_requests" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "kanban_write_requests_select" ON "public"."kanban_write_requests" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

ALTER TABLE "public"."notification_preferences" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "notification_preferences_insert_own" ON "public"."notification_preferences" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "notification_preferences_select_own" ON "public"."notification_preferences" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "notification_preferences_update_own" ON "public"."notification_preferences" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "notifications_select_own" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "notifications_update_own" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "own_attachment_cleanup" ON "public"."task_attachment_cleanup" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

ALTER TABLE "public"."project_milestones" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "project_milestones_delete" ON "public"."project_milestones" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE (("p"."id" = "project_milestones"."project_id") AND ("p"."owner_id" = "auth"."uid"()) AND (("p"."status")::"text" <> 'archived'::"text")))));

CREATE POLICY "project_milestones_insert" ON "public"."project_milestones" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE (("p"."id" = "project_milestones"."project_id") AND ("p"."owner_id" = "auth"."uid"()) AND (("p"."status")::"text" <> 'archived'::"text")))));

CREATE POLICY "project_milestones_select" ON "public"."project_milestones" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE (("p"."id" = "project_milestones"."project_id") AND ("p"."owner_id" = "auth"."uid"())))));

CREATE POLICY "project_milestones_update" ON "public"."project_milestones" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE (("p"."id" = "project_milestones"."project_id") AND ("p"."owner_id" = "auth"."uid"()) AND (("p"."status")::"text" <> 'archived'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE (("p"."id" = "project_milestones"."project_id") AND ("p"."owner_id" = "auth"."uid"()) AND (("p"."status")::"text" <> 'archived'::"text")))));

ALTER TABLE "public"."project_push_devices" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "project_push_devices_delete_own" ON "public"."project_push_devices" FOR DELETE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "project_push_devices_insert_own" ON "public"."project_push_devices" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "project_push_devices_select_own" ON "public"."project_push_devices" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));

CREATE POLICY "project_push_devices_update_own" ON "public"."project_push_devices" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));

ALTER TABLE "public"."projects" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "recommendation_item_read" ON "public"."task_recommendation_items" FOR SELECT TO "authenticated" USING ("public"."owns_bookmark_task"("task_id"));

CREATE POLICY "recommendation_set_read" ON "public"."task_recommendation_sets" FOR SELECT TO "authenticated" USING ("public"."owns_bookmark_task"("task_id"));

ALTER TABLE "public"."resource_analysis_jobs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."resource_embeddings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."resource_extractions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."resource_index" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."task_activity_logs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."task_attachment_cleanup" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."task_attachments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."task_checklist_items" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."task_recommendation_items" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."task_recommendation_sets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."task_resource_bookmarks" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."task_tag_links" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."task_tags" ENABLE ROW LEVEL SECURITY;

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."notifications";

REVOKE ALL ON FUNCTION "public"."assert_owned_kanban_board"("p_board_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."assert_owned_kanban_board"("p_board_id" "uuid") TO "anon";

GRANT ALL ON FUNCTION "public"."assert_owned_kanban_board"("p_board_id" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."assert_owned_kanban_board"("p_board_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."backfill_resource_embeddings"("p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."backfill_resource_embeddings"("p_limit" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."begin_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."begin_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."check_task_milestone_project"() TO "anon";

GRANT ALL ON FUNCTION "public"."check_task_milestone_project"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."check_task_milestone_project"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."claim_resource_analysis_job"("p_resource_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."claim_resource_analysis_job"("p_resource_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."claim_resource_embedding"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."claim_resource_embedding"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."claim_resource_extraction"("p_lease_seconds" integer, "p_type" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."claim_resource_extraction"("p_lease_seconds" integer, "p_type" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."claim_resource_image"("p_project_url" "text", "p_bucket" "text", "p_draft_resource_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."claim_resource_image"("p_project_url" "text", "p_bucket" "text", "p_draft_resource_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."claim_video_transcript"("p_lease_seconds" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."claim_video_transcript"("p_lease_seconds" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."complete_resource_analysis_job"("p_job_id" "uuid", "p_claim_token" "uuid", "p_resource" "jsonb", "p_transcript" "jsonb", "p_keywords" "text"[], "p_topic_tags" "text"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."complete_resource_analysis_job"("p_job_id" "uuid", "p_claim_token" "uuid", "p_resource" "jsonb", "p_transcript" "jsonb", "p_keywords" "text"[], "p_topic_tags" "text"[]) TO "service_role";

REVOKE ALL ON FUNCTION "public"."complete_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_extracted_text" "text", "p_language" "text", "p_segments" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."complete_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_extracted_text" "text", "p_language" "text", "p_segments" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."complete_resource_image"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_resource" "jsonb", "p_description" "text", "p_keywords" "text"[], "p_topic_tags" "text"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."complete_resource_image"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_resource" "jsonb", "p_description" "text", "p_keywords" "text"[], "p_topic_tags" "text"[]) TO "service_role";

REVOKE ALL ON FUNCTION "public"."complete_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_token" "uuid", "p_sources" "jsonb", "p_model_id" "text", "p_text_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."complete_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_token" "uuid", "p_sources" "jsonb", "p_model_id" "text", "p_text_version" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."complete_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_transcript_text" "text", "p_language" "text", "p_segments" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."complete_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_transcript_text" "text", "p_language" "text", "p_segments" "jsonb") TO "service_role";

GRANT ALL ON TABLE "public"."project_milestones" TO "service_role";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."project_milestones" TO "authenticated";

REVOKE ALL ON FUNCTION "public"."create_project_milestone"("p_board_id" "uuid", "p_request_id" "text", "p_title" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."create_project_milestone"("p_board_id" "uuid", "p_request_id" "text", "p_title" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."create_project_milestone"("p_board_id" "uuid", "p_request_id" "text", "p_title" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."delete_kanban_task_attachment"("p_attachment_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."delete_kanban_task_attachment"("p_attachment_id" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."delete_kanban_task_attachment"("p_attachment_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."delete_owned_task_tag"("p_tag_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."delete_owned_task_tag"("p_tag_id" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."delete_owned_task_tag"("p_tag_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."delete_task_checklist_item"("p_item_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."delete_task_checklist_item"("p_item_id" "uuid") TO "anon";

GRANT ALL ON FUNCTION "public"."delete_task_checklist_item"("p_item_id" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."delete_task_checklist_item"("p_item_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."enqueue_app_notification"("p_notification" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enqueue_app_notification"("p_notification" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."enqueue_discovered_extraction"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text", "p_allow_draft" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enqueue_discovered_extraction"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text", "p_allow_draft" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."enqueue_discovered_video"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text", "p_allow_draft" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enqueue_discovered_video"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text", "p_allow_draft" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."enqueue_ready_resource_analysis"("p_resource_id" "uuid", "p_allow_draft" boolean, "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enqueue_ready_resource_analysis"("p_resource_id" "uuid", "p_allow_draft" boolean, "p_limit" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."enqueue_resource_analysis"("p_resource_id" "uuid", "p_allow_draft" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enqueue_resource_analysis"("p_resource_id" "uuid", "p_allow_draft" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."enqueue_resource_embedding"("p_resource_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enqueue_resource_embedding"("p_resource_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."enqueue_stalled_period_alert"("p_task_id" "uuid", "p_user_id" "uuid", "p_stalled_at" timestamp with time zone, "p_resource_id" "uuid", "p_resource_version" "text", "p_task_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enqueue_stalled_period_alert"("p_task_id" "uuid", "p_user_id" "uuid", "p_stalled_at" timestamp with time zone, "p_resource_id" "uuid", "p_resource_version" "text", "p_task_version" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."enqueue_video_analysis"("p_transcript_id" "uuid", "p_allow_draft" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enqueue_video_analysis"("p_transcript_id" "uuid", "p_allow_draft" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."enqueue_video_transcription"("p_resource_id" "text", "p_source_file_id" "text", "p_source_version" "text", "p_storage_bucket" "text", "p_storage_path" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."enqueue_video_transcription"("p_resource_id" "text", "p_source_file_id" "text", "p_source_version" "text", "p_storage_bucket" "text", "p_storage_path" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."fail_resource_analysis_job"("p_job_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text", "p_skip" boolean, "p_retry_after_seconds" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."fail_resource_analysis_job"("p_job_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text", "p_skip" boolean, "p_retry_after_seconds" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."fail_resource_embedding"("p_resource_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."fail_resource_embedding"("p_resource_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."fail_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."fail_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."fail_resource_image"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text", "p_retry_after_seconds" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."fail_resource_image"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text", "p_retry_after_seconds" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."fail_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_token" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."fail_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid", "p_token" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."fail_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."fail_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_error_code" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."invoke_generate_notifications"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."invoke_project_notification_generator"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."invoke_resource_analysis_queue"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."is_image_resource"("p_resource" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."is_image_resource"("p_resource" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."is_pdf_resource"("p_resource" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."is_pdf_resource"("p_resource" "jsonb") TO "service_role";

GRANT ALL ON FUNCTION "public"."keep_board_milestone_project"() TO "anon";

GRANT ALL ON FUNCTION "public"."keep_board_milestone_project"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."keep_board_milestone_project"() TO "service_role";

GRANT ALL ON FUNCTION "public"."keep_milestone_project"() TO "anon";

GRANT ALL ON FUNCTION "public"."keep_milestone_project"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."keep_milestone_project"() TO "service_role";

GRANT ALL ON FUNCTION "public"."notification_preferences_timestamp"() TO "anon";

GRANT ALL ON FUNCTION "public"."notification_preferences_timestamp"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."notification_preferences_timestamp"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."notification_project_candidates"("p_offset" integer, "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."notification_project_candidates"("p_offset" integer, "p_limit" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."notification_read_only_update"() TO "anon";

GRANT ALL ON FUNCTION "public"."notification_read_only_update"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."notification_read_only_update"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."notification_task_candidates"("p_offset" integer, "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."notification_task_candidates"("p_offset" integer, "p_limit" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."owns_bookmark_task"("p_task_id" "uuid", "p_writable" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."owns_bookmark_task"("p_task_id" "uuid", "p_writable" boolean) TO "authenticated";

GRANT ALL ON FUNCTION "public"."owns_bookmark_task"("p_task_id" "uuid", "p_writable" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."queue_deleted_task_attachment"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."queue_deleted_task_attachment"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."queue_ready_transcript_analysis"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."queue_ready_transcript_analysis"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."queue_resource_embedding_after_analysis"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."queue_resource_embedding_after_analysis"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."queue_saved_resource_analysis"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."queue_saved_resource_analysis"() TO "service_role";

GRANT ALL ON TABLE "public"."resource_extractions" TO "service_role";

REVOKE ALL ON FUNCTION "public"."read_ready_resource_extraction"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."read_ready_resource_extraction"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text") TO "service_role";

GRANT ALL ON TABLE "public"."video_transcripts" TO "service_role";

REVOKE ALL ON FUNCTION "public"."read_ready_video_transcript"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."read_ready_video_transcript"("p_resource_id" "uuid", "p_external_url" "text", "p_storage_bucket" "text", "p_storage_path" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."read_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."read_task_recommendations"("p_task_id" "uuid", "p_user_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."recommendation_jaccard"("a" "text"[], "b" "text"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."recommendation_jaccard"("a" "text"[], "b" "text"[]) TO "service_role";

REVOKE ALL ON FUNCTION "public"."recommendation_load_owned_task"("p_task_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."recommendation_load_owned_task"("p_task_id" "uuid", "p_user_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."recommendation_load_owned_task"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."recommendation_load_owned_task"("p_task_id" "uuid", "p_user_id" "uuid", "p_mode" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."recommendation_resources_for_recipient"("p_user_id" "uuid", "p_ids" "uuid"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."recommendation_resources_for_recipient"("p_user_id" "uuid", "p_ids" "uuid"[]) TO "service_role";

REVOKE ALL ON FUNCTION "public"."recommendation_rls_resources"("p_ids" "uuid"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."recommendation_rls_resources"("p_ids" "uuid"[]) TO "service_role";

REVOKE ALL ON FUNCTION "public"."register_project_push_device"("p_fcm_token" "text", "p_platform" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."register_project_push_device"("p_fcm_token" "text", "p_platform" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."register_project_push_device"("p_fcm_token" "text", "p_platform" "text") TO "service_role";

GRANT ALL ON TABLE "public"."task_attachments" TO "authenticated";

GRANT ALL ON TABLE "public"."task_attachments" TO "service_role";

REVOKE ALL ON FUNCTION "public"."register_task_attachment"("p_task_id" "uuid", "p_file_name" "text", "p_storage_path" "text", "p_mime_type" "text", "p_file_size" bigint) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."register_task_attachment"("p_task_id" "uuid", "p_file_name" "text", "p_storage_path" "text", "p_mime_type" "text", "p_file_size" bigint) TO "anon";

GRANT ALL ON FUNCTION "public"."register_task_attachment"("p_task_id" "uuid", "p_file_name" "text", "p_storage_path" "text", "p_mime_type" "text", "p_file_size" bigint) TO "authenticated";

GRANT ALL ON FUNCTION "public"."register_task_attachment"("p_task_id" "uuid", "p_file_name" "text", "p_storage_path" "text", "p_mime_type" "text", "p_file_size" bigint) TO "service_role";

REVOKE ALL ON FUNCTION "public"."renew_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_lease_seconds" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."renew_resource_extraction"("p_extraction_id" "uuid", "p_claim_token" "uuid", "p_lease_seconds" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."renew_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_lease_seconds" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."renew_video_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_lease_seconds" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."reorder_kanban_tasks"("p_tasks" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."reorder_kanban_tasks"("p_tasks" "jsonb") TO "anon";

GRANT ALL ON FUNCTION "public"."reorder_kanban_tasks"("p_tasks" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "public"."reorder_kanban_tasks"("p_tasks" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."reorder_task_checklist"("p_task_id" "uuid", "p_items" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."reorder_task_checklist"("p_task_id" "uuid", "p_items" "jsonb") TO "anon";

GRANT ALL ON FUNCTION "public"."reorder_task_checklist"("p_task_id" "uuid", "p_items" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "public"."reorder_task_checklist"("p_task_id" "uuid", "p_items" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."replace_generated_task_list"("p_board_id" "uuid", "p_request_id" "text", "p_expected_version" "text", "p_tasks" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."replace_generated_task_list"("p_board_id" "uuid", "p_request_id" "text", "p_expected_version" "text", "p_tasks" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "public"."replace_generated_task_list"("p_board_id" "uuid", "p_request_id" "text", "p_expected_version" "text", "p_tasks" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."replay_skilltrack_write"("p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."replay_skilltrack_write"("p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "public"."replay_skilltrack_write"("p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."resource_analysis_candidates"("p_resource_id" "uuid", "p_allow_draft" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."resource_analysis_candidates"("p_resource_id" "uuid", "p_allow_draft" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."resource_analysis_storage_key"("p_url" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."resource_analysis_storage_key"("p_url" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."resource_analysis_version"("p_resource" "jsonb", "p_transcript" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."resource_analysis_version"("p_resource" "jsonb", "p_transcript" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."resource_extraction_candidates"("p_limit" integer, "p_after_id" "uuid", "p_draft_resource_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."resource_extraction_candidates"("p_limit" integer, "p_after_id" "uuid", "p_draft_resource_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."save_generated_tasks"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_generated_tasks"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "public"."save_generated_tasks"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."save_generated_tasks_with_milestones"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_generated_tasks_with_milestones"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "public"."save_generated_tasks_with_milestones"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."save_kanban_task_edit"("p_task_id" "uuid", "p_expected_updated_at" timestamp with time zone, "p_request_id" "text", "p_changes" "jsonb", "p_add_tag_ids" "uuid"[], "p_remove_tag_ids" "uuid"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_kanban_task_edit"("p_task_id" "uuid", "p_expected_updated_at" timestamp with time zone, "p_request_id" "text", "p_changes" "jsonb", "p_add_tag_ids" "uuid"[], "p_remove_tag_ids" "uuid"[]) TO "authenticated";

GRANT ALL ON FUNCTION "public"."save_kanban_task_edit"("p_task_id" "uuid", "p_expected_updated_at" timestamp with time zone, "p_request_id" "text", "p_changes" "jsonb", "p_add_tag_ids" "uuid"[], "p_remove_tag_ids" "uuid"[]) TO "service_role";

REVOKE ALL ON FUNCTION "public"."save_new_skilltrack_project"("p_request_id" "text", "p_name" "text", "p_description" "text", "p_constraints" "text", "p_start_date" "date", "p_end_date" "date", "p_tasks" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_new_skilltrack_project"("p_request_id" "text", "p_name" "text", "p_description" "text", "p_constraints" "text", "p_start_date" "date", "p_end_date" "date", "p_tasks" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "public"."save_new_skilltrack_project"("p_request_id" "text", "p_name" "text", "p_description" "text", "p_constraints" "text", "p_start_date" "date", "p_end_date" "date", "p_tasks" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."save_replacement_task_drafts"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_replacement_task_drafts"("p_board_id" "uuid", "p_request_id" "text", "p_tasks" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."save_resource_analysis"("p_user_id" "uuid", "p_resource" "jsonb", "p_transcript" "jsonb", "p_keywords" "text"[], "p_topic_tags" "text"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_resource_analysis"("p_user_id" "uuid", "p_resource" "jsonb", "p_transcript" "jsonb", "p_keywords" "text"[], "p_topic_tags" "text"[]) TO "service_role";

REVOKE ALL ON FUNCTION "public"."save_skilltrack_task_action"("p_board_id" "uuid", "p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."save_skilltrack_task_action"("p_board_id" "uuid", "p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") TO "authenticated";

GRANT ALL ON FUNCTION "public"."save_skilltrack_task_action"("p_board_id" "uuid", "p_operation" "text", "p_request_id" "text", "p_payload" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."set_task_resource_bookmark"("p_task_id" "uuid", "p_resource_id" "uuid", "p_saved" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."set_task_resource_bookmark"("p_task_id" "uuid", "p_resource_id" "uuid", "p_saved" boolean) TO "authenticated";

GRANT ALL ON FUNCTION "public"."set_task_resource_bookmark"("p_task_id" "uuid", "p_resource_id" "uuid", "p_saved" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."skilltrack_receipt_key"("p_operation" "text", "p_request_id" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."skilltrack_receipt_key"("p_operation" "text", "p_request_id" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."skilltrack_receipt_key"("p_operation" "text", "p_request_id" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."stalled_period_alert_state"("p_task_id" "uuid", "p_user_id" "uuid", "p_stalled_at" timestamp with time zone) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."stalled_period_alert_state"("p_task_id" "uuid", "p_user_id" "uuid", "p_stalled_at" timestamp with time zone) TO "service_role";

REVOKE ALL ON FUNCTION "public"."task_list_replacement_context"("p_board_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."task_list_replacement_context"("p_board_id" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."task_list_replacement_context"("p_board_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."task_recommendations"("p_task_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."task_recommendations"("p_task_id" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."task_recommendations"("p_task_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."task_saved_resources"("p_task_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."task_saved_resources"("p_task_id" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."task_saved_resources"("p_task_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."unregister_project_push_device"("p_fcm_token" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."unregister_project_push_device"("p_fcm_token" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."unregister_project_push_device"("p_fcm_token" "text") TO "service_role";

GRANT ALL ON TABLE "public"."kanban_tasks" TO "authenticated";

GRANT ALL ON TABLE "public"."kanban_tasks" TO "service_role";

REVOKE ALL ON FUNCTION "public"."update_kanban_task_tracking"("p_task_id" "uuid", "p_action" "text", "p_expected_updated_at" timestamp with time zone, "p_status" "text", "p_sort_order" bigint) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."update_kanban_task_tracking"("p_task_id" "uuid", "p_action" "text", "p_expected_updated_at" timestamp with time zone, "p_status" "text", "p_sort_order" bigint) TO "authenticated";

GRANT ALL ON FUNCTION "public"."update_kanban_task_tracking"("p_task_id" "uuid", "p_action" "text", "p_expected_updated_at" timestamp with time zone, "p_status" "text", "p_sort_order" bigint) TO "service_role";

REVOKE ALL ON FUNCTION "public"."update_task_stagnation"("p_task_id" "uuid", "p_score" smallint, "p_checked_at" timestamp with time zone) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."update_task_stagnation"("p_task_id" "uuid", "p_score" smallint, "p_checked_at" timestamp with time zone) TO "service_role";

REVOKE ALL ON FUNCTION "public"."video_transcription_candidates"("p_limit" integer, "p_after_id" "uuid", "p_draft_resource_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."video_transcription_candidates"("p_limit" integer, "p_after_id" "uuid", "p_draft_resource_id" "uuid") TO "service_role";

GRANT ALL ON TABLE "public"."kanban_boards" TO "authenticated";

GRANT ALL ON TABLE "public"."kanban_boards" TO "service_role";

GRANT ALL ON TABLE "public"."kanban_write_requests" TO "service_role";

GRANT SELECT,INSERT ON TABLE "public"."kanban_write_requests" TO "authenticated";

GRANT ALL ON TABLE "public"."notification_preferences" TO "anon";

GRANT ALL ON TABLE "public"."notification_preferences" TO "authenticated";

GRANT ALL ON TABLE "public"."notification_preferences" TO "service_role";

GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."notifications" TO "anon";

GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."notifications" TO "authenticated";

GRANT ALL ON TABLE "public"."notifications" TO "service_role";

GRANT ALL ON TABLE "public"."project_push_devices" TO "authenticated";

GRANT ALL ON TABLE "public"."project_push_devices" TO "service_role";

GRANT ALL ON TABLE "public"."projects" TO "authenticated";

GRANT ALL ON TABLE "public"."projects" TO "service_role";

GRANT ALL ON TABLE "public"."resource_analysis_jobs" TO "service_role";

GRANT ALL ON TABLE "public"."resource_index" TO "service_role";

GRANT ALL ON TABLE "public"."recommendation_index_sources" TO "service_role";

GRANT ALL ON TABLE "public"."resource_embeddings" TO "service_role";

GRANT ALL ON TABLE "public"."task_activity_logs" TO "authenticated";

GRANT ALL ON TABLE "public"."task_activity_logs" TO "service_role";

GRANT ALL ON TABLE "public"."task_attachment_cleanup" TO "service_role";

GRANT SELECT,INSERT,DELETE ON TABLE "public"."task_attachment_cleanup" TO "authenticated";

GRANT ALL ON TABLE "public"."task_checklist_items" TO "authenticated";

GRANT ALL ON TABLE "public"."task_checklist_items" TO "service_role";

GRANT ALL ON TABLE "public"."task_recommendation_items" TO "service_role";

GRANT SELECT ON TABLE "public"."task_recommendation_items" TO "authenticated";

GRANT ALL ON TABLE "public"."task_recommendation_sets" TO "service_role";

GRANT SELECT ON TABLE "public"."task_recommendation_sets" TO "authenticated";

GRANT ALL ON TABLE "public"."task_resource_bookmarks" TO "service_role";

GRANT SELECT,INSERT,DELETE ON TABLE "public"."task_resource_bookmarks" TO "authenticated";

GRANT ALL ON TABLE "public"."task_tag_links" TO "authenticated";

GRANT ALL ON TABLE "public"."task_tag_links" TO "service_role";

GRANT ALL ON TABLE "public"."task_tags" TO "authenticated";

GRANT ALL ON TABLE "public"."task_tags" TO "service_role";

-- Custom platform objects require public names to resolve during CREATE.
SET search_path = public, extensions;

-- Marketplace Auth/Storage customizations
-- Custom Auth and Storage DDL only; no table data.
-- Restore after the application schema into a Supabase project.

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_account();

DROP POLICY IF EXISTS "Mentors upload their reading files" ON storage.objects;
CREATE POLICY "Mentors upload their reading files" ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'mentor-reading-files'::text) AND can_author_content() AND (name ~ (('^'::text || (auth.uid())::text) || '/[0-9a-f]{32}\.(pdf|png|jpg|jpeg|mp4)$'::text))));

DROP POLICY IF EXISTS "Read files attached to accessible learning resources" ON storage.objects;
CREATE POLICY "Read files attached to accessible learning resources" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'mentor-reading-files'::text) AND (EXISTS ( SELECT 1
   FROM learning_resources r
  WHERE ((r.attachment_path = objects.name) AND can_read_mentor_resource(r.author_id, r.status, r.moderation_hidden))))));

DROP POLICY IF EXISTS "Read own qualification evidence" ON storage.objects;
CREATE POLICY "Read own qualification evidence" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'mentor-qualifications'::text) AND is_verified_account() AND (split_part(name, '/'::text, 1) = (auth.uid())::text)));

DROP POLICY IF EXISTS "Remove unattached qualification evidence" ON storage.objects;
CREATE POLICY "Remove unattached qualification evidence" ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated USING (((bucket_id = 'mentor-qualifications'::text) AND is_verified_account() AND (split_part(name, '/'::text, 1) = (auth.uid())::text) AND (NOT (EXISTS ( SELECT 1
   FROM tutor_profiles
  WHERE (tutor_profiles.qualification_path = objects.name))))));

DROP POLICY IF EXISTS "Upload own qualification evidence" ON storage.objects;
CREATE POLICY "Upload own qualification evidence" ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'mentor-qualifications'::text) AND can_author_content() AND (split_part(name, '/'::text, 1) = (auth.uid())::text) AND (array_length(string_to_array(name, '/'::text), 1) = 2) AND (split_part(name, '/'::text, 2) ~ '^[A-Za-z0-9_-]+[.](pdf|jpg|jpeg|png)$'::text)));

-- SkillTrack Auth/Storage customizations
-- Custom Auth and Storage DDL only; no table data.
-- Restore after the application schema into a Supabase project.

DROP POLICY IF EXISTS "Users can delete own task files" ON storage.objects;
CREATE POLICY "Users can delete own task files" ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated USING (((bucket_id = 'task-attachments'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text)));

DROP POLICY IF EXISTS "Users can read own task files" ON storage.objects;
CREATE POLICY "Users can read own task files" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated USING (((bucket_id = 'task-attachments'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text)));

DROP POLICY IF EXISTS "Users can update own task files" ON storage.objects;
CREATE POLICY "Users can update own task files" ON storage.objects AS PERMISSIVE FOR UPDATE TO authenticated USING (((bucket_id = 'task-attachments'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text))) WITH CHECK (((bucket_id = 'task-attachments'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text)));

DROP POLICY IF EXISTS "Users can upload own task files" ON storage.objects;
CREATE POLICY "Users can upload own task files" ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'task-attachments'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text)));

SET search_path = '';
SET row_security = on;
COMMIT;
NOTIFY pgrst, 'reload schema';
