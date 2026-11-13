-- Run after the educational content migration on existing and new projects.
-- Existing resources keep their category until their author recategorizes them.
begin;

alter table public.learning_resources
  drop constraint learning_resources_category_check;

alter table public.learning_resources
  add constraint learning_resources_category_check
  check (category in (
    'Programming',
    'Cyber Security',
    'Cloud Computing',
    'Data Science',
    'Mobile Application Design'
  )) not valid;

-- NOT VALID preserves existing rows; new/updated rows must use the new list.
commit;
notify pgrst, 'reload schema';
