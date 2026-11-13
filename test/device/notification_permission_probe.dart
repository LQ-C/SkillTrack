// Offline Android smoke entry point. Build ONLY with an isolated application ID.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/features/notifications/services/notification_installation_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final installation = AndroidNotificationInstallationService();
  final before = await installation.read('offline-fixture');
  const action = String.fromEnvironment(
    'PERMISSION_PROBE_ACTION',
    defaultValue: 'inspect',
  );
  final effectiveAction = action == 'inspect'
      ? WidgetsBinding.instance.platformDispatcher.defaultRouteName
      : action;
  if (effectiveAction == '/not-now' || effectiveAction == 'not-now') {
    await installation.markHandled();
  }
  if (effectiveAction == '/requested') await installation.markRequested();
  if (effectiveAction == '/settings') await installation.openSettings();
  final state = await installation.read('offline-fixture');
  debugPrint(
    'PERMISSION_PROBE ${jsonEncode({
      'before': {'granted': before.granted, 'canRequest': before.canRequest, 'handled': before.handled},
      'after': {'granted': state.granted, 'canRequest': state.canRequest, 'handled': state.handled},
      'action': action,
      'backendRequests': 0,
    })}',
  );
  runApp(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        appBar: AppBar(title: const Text('Offline permission probe')),
        body: Column(
          children: [
            Text(
              'Granted: ${state.granted}; retry: ${state.canRequest}; handled: ${state.handled}',
            ),
            FilledButton(
              onPressed: () async {
                await installation.markRequested();
                final granted = await FlutterLocalNotificationsPlugin()
                    .resolvePlatformSpecificImplementation<
                      AndroidFlutterLocalNotificationsPlugin
                    >()!
                    .requestNotificationsPermission();
                debugPrint('PERMISSION_PROBE explicit_enable_result=$granted');
              },
              child: const Text('Enable Notifications'),
            ),
            TextButton(
              onPressed: installation.openSettings,
              child: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    ),
  );
}
