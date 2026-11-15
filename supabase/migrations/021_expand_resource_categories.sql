-- Expand category choices without changing any existing records or RLS.
begin;
do $migration$
declare
  previous_expression text;
begin
  select pg_get_expr(conbin,conrelid) into previous_expression
  from pg_constraint where conrelid='public.learning_resources'::regclass
    and conname='learning_resources_category_check' and contype='c';
  if previous_expression is null then
    raise exception 'Expected learning_resources_category_check was not found; inspect category constraints before applying';
  end if;
  -- Preserve every value accepted by the installed constraint, even on projects
  -- whose historical category list differs from this checkout.
  alter table public.learning_resources drop constraint learning_resources_category_check;
  execute format(
    'alter table public.learning_resources add constraint learning_resources_category_check check ((%s) or category = any (%L::text[])) not valid',
    previous_expression,
    array['Programming','Cyber Security','Cloud Computing','Data Science','Mobile Application Design','Web Development','Backend & API Development','Databases','Software Architecture','Software Testing','Version Control & Collaboration']
  );
end $migration$;
-- NOT VALID avoids scanning/reclassifying historical rows. New writes enforce
-- the union above. Existing unrelated invalid rows are not modified.
notify pgrst,'reload schema';
commit;
