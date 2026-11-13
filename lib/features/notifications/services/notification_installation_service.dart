import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NotificationInstallation {
  const NotificationInstallation({
    required this.granted,
    required this.canRequest,
    this.handled = false,
    this.optedOut = false,
  });
  final bool granted, canRequest, handled, optedOut;
}

abstract interface class NotificationInstallationService {
  bool get supported;
  Future<NotificationInstallation> read(String user);
  Future<void> markHandled();
  Future<void> markRequested();
  Future<void> rememberChoice(String user, bool enabled);
  Future<void> openSettings();
}

class AndroidNotificationInstallationService
    implements NotificationInstallationService {
  static const channel = MethodChannel('skilltrack/notification_permission');
  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  @override
  Future<NotificationInstallation> read(String user) async {
    final data =
        await channel.invokeMapMethod<String, dynamic>('status', {
          'user': user,
        }) ??
        {};
    return NotificationInstallation(
      granted: data['granted'] == true,
      canRequest: data['canRequest'] == true,
      handled: data['handled'] == true,
      optedOut: data['optedOut'] == true,
    );
  }

  @override
  Future<void> markHandled() => channel.invokeMethod<void>('handled');
  @override
  Future<void> markRequested() => channel.invokeMethod<void>('requested');
  @override
  Future<void> rememberChoice(String user, bool enabled) =>
      channel.invokeMethod<void>('choice', {'user': user, 'enabled': enabled});
  @override
  Future<void> openSettings() => channel.invokeMethod<void>('settings');
}
