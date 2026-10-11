import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/skill_track_app.dart';
import 'features/kanban/repositories/supabase_kanban_repository.dart';
import 'features/projects/repositories/supabase_project_repository.dart';
import 'features/notifications/repositories/supabase_notification_repository.dart';
import 'features/notifications/services/notification_realtime_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config =
      jsonDecode(await rootBundle.loadString('config/supabase.json'))
          as Map<String, dynamic>;
  final url = config['SUPABASE_URL'] as String?;
  final key = config['SUPABASE_PUBLISHABLE_KEY'] as String?;
  if (url == null || url.isEmpty || key == null || key.isEmpty) {
    throw StateError('Invalid Supabase configuration.');
  }
  await Supabase.initialize(url: url, publishableKey: key);
  runApp(
    SkillTrackApp(
      projectRepository: SupabaseProjectRepository(Supabase.instance.client),
      kanbanRepository: SupabaseKanbanRepository(Supabase.instance.client),
      notificationRepository: SupabaseNotificationRepository(
        Supabase.instance.client,
      ),
      realtimeService: NotificationRealtimeService(
        SupabaseNotificationRealtimeTransport(Supabase.instance.client),
      ),
      authEvents: Supabase.instance.client.auth.onAuthStateChange,
    ),
  );
}
