-- Regression checks for the combined schema. Run ONLY in an isolated test DB.
-- Fixture data is rolled back at the end.
BEGIN;
DO $$
DECLARE columns text[];
BEGIN
  SELECT array_agg(column_name::text ORDER BY ordinal_position) INTO columns
  FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles';
  IF columns <> ARRAY['id','full_name','date_of_birth','role','bio','created_at','updated_at'] THEN
    RAISE EXCEPTION 'Marketplace profile columns differ: %', columns;
  END IF;
  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public') <> 33 THEN
    RAISE EXCEPTION 'Expected 33 public tables';
  END IF;
  IF has_table_privilege('authenticated','public.profiles','INSERT')
     OR has_table_privilege('authenticated','public.profiles','DELETE')
     OR has_column_privilege('authenticated','public.profiles','id','UPDATE') THEN
    RAISE EXCEPTION 'Legacy SkillTrack profile write permissions leaked';
  END IF;
  IF has_schema_privilege('authenticated','public','CREATE') THEN
    RAISE EXCEPTION 'Temporary ownership-transfer privilege was not revoked';
  END IF;
  IF to_regprocedure('supabase_functions.http_request()') IS NULL THEN
    IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='project-push-notification-dispatcher') THEN
      RAISE EXCEPTION 'Push trigger should be deferred when Webhooks are absent';
    END IF;
  ELSIF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='project-push-notification-dispatcher' AND tgenabled='D') THEN
    RAISE EXCEPTION 'Configured-platform push trigger must exist and remain disabled';
  END IF;
END $$;
SELECT 'PASS: canonical profile fields, 33 tables, restricted profile ACLs, temporary grant revoked, old push disabled' AS result;

INSERT INTO auth.users(id,email,email_confirmed_at,raw_user_meta_data) VALUES
('00000000-0000-0000-0000-000000000001','mentor@merge.test',now(),'{"full_name":"Merge Mentor","date_of_birth":"2000-01-01","role":"mentor"}'),
('00000000-0000-0000-0000-000000000002','student@merge.test',now(),'{"full_name":"Merge Student","date_of_birth":"2001-01-01","role":"student"}'),
('00000000-0000-0000-0000-000000000003','other@merge.test',now(),'{"full_name":"Other Student","date_of_birth":"2002-01-01","role":"student"}'),
('00000000-0000-0000-0000-000000000004','unverified@merge.test',null,'{"full_name":"Unverified Student","date_of_birth":"2002-01-01","role":"student"}');
DO $$ BEGIN
  IF (SELECT count(*) FROM public.profiles) <> 4
     OR NOT EXISTS(SELECT 1 FROM public.content_publishers WHERE user_id='00000000-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'Signup/profile/mentor publishing triggers failed';
  END IF;
END $$;
UPDATE public.tutor_profiles SET headline='Programming', expertise='Flutter forms',is_listed=true
WHERE user_id='00000000-0000-0000-0000-000000000001';
SELECT 'PASS: signup creates marketplace profiles and mentor publishing permission' AS result;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
SELECT public.save_mentor_payment_offer(5000);
WITH created AS (
INSERT INTO public.learning_resources(author_id,title,summary,category,difficulty,kind,external_url,body,status)
VALUES('00000000-0000-0000-0000-000000000001',
  'Flutter forms','Learn Flutter forms and input validation with practical examples.',
  'Programming','Beginner','Reading','https://example.test/flutter','Flutter forms, input validation and TextFormField examples.','published')
RETURNING id
) SELECT set_config('test.resource_id',id::text,true) FROM created;
DO $$ BEGIN
  IF (SELECT author_name FROM public.learning_resources WHERE id=current_setting('test.resource_id')::uuid) <> 'Merge Mentor' THEN
    RAISE EXCEPTION 'Mentor author stamp failed';
  END IF;
END $$;
RESET ROLE;
DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.resource_analysis_jobs WHERE resource_id=current_setting('test.resource_id')::uuid) THEN
    RAISE EXCEPTION 'SkillTrack analysis trigger was lost while merging shared resource table';
  END IF;
END $$;
SELECT 'PASS: mentor publication retains author stamping and SkillTrack analysis enqueue' AS result;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
DO $$ BEGIN
  IF (SELECT count(*) FROM public.profiles) <> 1 THEN RAISE EXCEPTION 'Own-profile RLS failed'; END IF;
  IF EXISTS(SELECT 1 FROM public.learning_resources) THEN RAISE EXCEPTION 'Unpaid student accessed paid material'; END IF;
END $$;
INSERT INTO public.projects(id,owner_id,name) VALUES
('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','Merged project');
INSERT INTO public.kanban_boards(id,project_id,name) VALUES
('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Merged board');
INSERT INTO public.kanban_tasks(id,board_id,title) VALUES
('40000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','Build a Flutter form');
DO $$ DECLARE order_id uuid; BEGIN
  SELECT id INTO order_id FROM public.prepare_mentor_checkout('00000000-0000-0000-0000-000000000001');
  PERFORM public.complete_demo_mentor_payment(order_id,'success');
  IF (SELECT count(*) FROM public.learning_resources) <> 1 THEN RAISE EXCEPTION 'Verified payment did not unlock material'; END IF;
END $$;
RESET ROLE;
DO $$ BEGIN
  IF (SELECT count(*) FROM public.recommendation_resources_for_recipient(
    '00000000-0000-0000-0000-000000000002',ARRAY[current_setting('test.resource_id')::uuid])) <> 1 THEN
    RAISE EXCEPTION 'Recommendation access helper did not honor paid access';
  END IF;
  IF EXISTS(SELECT 1 FROM public.recommendation_resources_for_recipient(
    '00000000-0000-0000-0000-000000000003',ARRAY[current_setting('test.resource_id')::uuid])) THEN
    RAISE EXCEPTION 'Recommendation access helper leaked material to unpaid user';
  END IF;
END $$;
SELECT 'PASS: unpaid material denied, successful demo payment unlocks it, recommendation helper honors recipient RLS' AS result;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM public.projects) OR EXISTS(SELECT 1 FROM public.kanban_tasks)
     OR EXISTS(SELECT 1 FROM public.learning_resources) THEN
    RAISE EXCEPTION 'Other student can access private projects/tasks/paid resources';
  END IF;
END $$;
RESET ROLE;
SELECT 'PASS: project/task ownership and unpaid-resource isolation preserved' AS result;

UPDATE public.learning_resources SET moderation_hidden=true WHERE id=current_setting('test.resource_id')::uuid;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM public.learning_resources) THEN RAISE EXCEPTION 'Moderation did not hide paid material'; END IF;
END $$;
RESET ROLE;
UPDATE public.learning_resources SET moderation_hidden=false WHERE id=current_setting('test.resource_id')::uuid;
SET LOCAL ROLE authenticated;
SELECT public.cancel_mentor_package('00000000-0000-0000-0000-000000000001');
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM public.learning_resources) THEN RAISE EXCEPTION 'Cancellation did not revoke material access'; END IF;
END $$;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',true);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM public.profiles) OR EXISTS(SELECT 1 FROM public.learning_resources) THEN
    RAISE EXCEPTION 'Unverified account can read protected marketplace data';
  END IF;
END $$;
RESET ROLE;
SELECT 'PASS: moderation, cancellation and email-verification restrictions preserved' AS result;
ROLLBACK;
