# skilltrack

Final Year Project "SkillTrack"

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Kanban reliability update

Apply `supabase/migrations/20261018000000_atomic_kanban_writes.sql` to the
existing database before running this client. Generated-task saves, task and
checklist ordering, checklist deletion, and attachment registration now use
transactional RPCs. The migration uses the existing Kanban tables and RLS
policies; it does not recreate the missing original schema.

Deploy the updated AI function after applying the migration:

```sh
npx supabase functions deploy generate-project-tasks
```

Generated previews keep one request identifier and an unchanged save payload
across retries. A successful save followed by a failed refresh is reported as
saved, with a request to refresh the board.

## Android release signing

Debug builds continue to use debug signing. Release builds use
`android/key.properties` when present and otherwise produce unsigned artifacts.
That ignored file must define `storeFile`, `storePassword`, `keyAlias`, and
`keyPassword` for your own release keystore. Keep signing material private.
