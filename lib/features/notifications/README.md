# In-app notification boundary

Apply `supabase/migrations/20261010000000_in_app_notifications.sql` before using
the module against Supabase. The Flutter app reads persisted notifications and
updates read state/preferences. `NotificationEventCoordinator` is an event-facing
API for a stalled-task monitor, deadline scheduler, and recommendation source.
These sources are not present in the current app, so no production events are
emitted yet. In particular, app startup does not schedule deadline reminders.
Use a trusted backend scheduler for deadline windows. The unique key and database
unique index protect against duplicate events. No push delivery is implemented.
