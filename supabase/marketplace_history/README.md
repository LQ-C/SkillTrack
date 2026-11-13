# Marketplace schema reference

The dated migration files are unmodified reference copies from TVliau75/Dud.
They are intentionally outside Supabase's automatic migration directory. Do not
replay them over an existing SkillTrack database: profiles, learning_resources,
triggers, policies and functions overlap, and later migrations supersede earlier
mentor approval, library-grant and test-payment behavior.

combined_schema_marketplace_profiles_v2.sql is a schema-only, guarded bootstrap
copied from the locally prepared 2026-11-12 combined-schema artifact. Its manifest
records the two export hashes. It is for a fresh integration test project only;
it does not import Auth users, resource files, rows, secrets or cron jobs.

local_test_platform.sql and validate_combined_schema.sql are prior isolated
PostgreSQL fixtures. Do not execute the platform fixture on hosted Supabase.
This integration did not rerun their full PostgreSQL restoration: Docker's
Linux engine was unavailable. The new migration was tested separately in PGlite.
See ../../docs/MARKETPLACE_INTEGRATION.md for the active setup order.
