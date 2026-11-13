import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'app/skill_track_app.dart';
import 'app/marketplace_dependencies.dart';
import 'app/views/setup_screen.dart';
import 'app/app_theme.dart';
import 'features/learning_integration/repositories/supabase_recommendation_repository.dart';
import 'features/kanban/repositories/supabase_kanban_repository.dart';
import 'features/projects/repositories/supabase_project_repository.dart';
import 'features/ai_task_generation/repositories/supabase_ai_task_generation_repository.dart';
import 'features/ai_task_generation/services/ai_task_generation_service.dart';
import 'features/notifications/repositories/supabase_notification_repository.dart';
import 'features/notifications/services/notification_realtime_service.dart';
import 'features/notifications/repositories/supabase_push_device_repository.dart';
import 'features/notifications/services/push_notification_service.dart';
import 'features/notifications/services/notification_installation_service.dart';
import 'features/notifications/viewmodels/push_notification_controller.dart';
import 'core/config/firebase_options.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (FirebasePushNotificationService.supportsCurrentPlatform) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }
  const definedUrl = String.fromEnvironment('SUPABASE_URL');
  const definedKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: String.fromEnvironment('SUPABASE_ANON_KEY'),
  );
  Map<String, dynamic> config = {};
  if (definedUrl.isEmpty || definedKey.isEmpty) {
    try {
      config =
          jsonDecode(await rootBundle.loadString('config/supabase.json'))
              as Map<String, dynamic>;
    } catch (_) {
      /* Missing local configuration opens setup. */
    }
  }
  final url = definedUrl.isNotEmpty
      ? definedUrl
      : config['SUPABASE_URL'] as String?;
  final key = definedKey.isNotEmpty
      ? definedKey
      : config['SUPABASE_PUBLISHABLE_KEY'] as String?;
  if (url == null || url.isEmpty || key == null || key.isEmpty) {
    runApp(
      MaterialApp(
        theme: AppTheme.light,
        home: const SetupScreen(
          message:
              'Add config/supabase.json using config/supabase.example.json, or provide SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY as Dart defines.',
        ),
      ),
    );
    return;
  }
  await Supabase.initialize(url: url, publishableKey: key);
  final client = Supabase.instance.client;
  final notifications = SupabaseNotificationRepository(client);
  final push = PushNotificationController(
    notifications,
    SupabasePushDeviceRepository(client),
    FirebasePushNotificationService(),
    installation: AndroidNotificationInstallationService(),
  );
  runApp(
    SkillTrackApp(
      marketplace: MarketplaceDependencies(client),
      projectRepository: SupabaseProjectRepository(client),
      recommendationRepository: SupabaseRecommendationRepository(client),
      kanbanRepository: SupabaseKanbanRepository(client),
      taskGenerationRepository: SupabaseTaskGenerationRepository(
        AiTaskGenerationService(client),
      ),
      notificationRepository: notifications,
      pushController: push,
      realtimeService: NotificationRealtimeService(
        SupabaseNotificationRealtimeTransport(client),
      ),
      authEvents: client.auth.onAuthStateChange,
    ),
  );
}
