import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/skill_track_app.dart';
import 'package:skilltrack/features/notifications/models/notification_preferences.dart';
import 'package:skilltrack/features/notifications/repositories/push_device_repository.dart';
import 'package:skilltrack/features/notifications/services/push_notification_service.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_preferences_view_model.dart';
import 'package:skilltrack/features/notifications/viewmodels/push_notification_controller.dart';
import 'package:skilltrack/features/notifications/views/notification_preferences_screen.dart';

import '../kanban/fake_repository.dart';
import '../projects/fake_project_repository.dart';
import 'fake_notification_repository.dart';

class MutablePreferences extends FakeNotificationRepository {
  String? user = 'user';
  int saves = 0;
  Completer<NotificationPreferences>? pendingPreferences;
  Completer<NotificationPreferences>? pendingSave;

  @override
  String? get currentUserId => user;

  @override
  Future<NotificationPreferences> getPreferences() =>
      pendingPreferences?.future ?? super.getPreferences();

  @override
  Future<NotificationPreferences> updatePreferences(
    NotificationPreferences preferences,
  ) {
    saves++;
    final gate = pendingSave;
    if (gate != null) {
      return gate.future.then((saved) => savedPreferences = saved);
    }
    return super.updatePreferences(preferences);
  }
}

class FakeDevices implements PushDeviceRepository {
  FakeDevices(this.preferences);
  final MutablePreferences preferences;
  final registrations = <String>[];
  final removals = <String>[];
  bool fail = false;

  @override
  String? get currentUserId => preferences.currentUserId;
  @override
  Future<void> register(String token) async {
    if (fail) throw StateError('offline');
    registrations.add('$currentUserId:$token');
  }

  @override
  Future<void> unregister(String token) async {
    if (fail) throw StateError('offline');
    removals.add(token);
  }
}

class FakePushService implements PushNotificationService {
  final tokens = StreamController<String>.broadcast();
  final opened = StreamController<PushNotificationTap>.broadcast();
  bool supported = true, authorized = true, enabled = false;
  int starts = 0, permissionRequests = 0, tokenReads = 0, invalidations = 0;
  String token = 'token-one';
  String? user;
  PushNotificationTap? initialTap;
  Completer<bool>? permissionGate;

  @override
  bool get isSupported => supported;
  @override
  Stream<String> get tokenChanges => tokens.stream;
  @override
  Stream<PushNotificationTap> get taps => opened.stream;
  @override
  Future<void> start(String userId) async {
    final first = user != userId;
    if (first) starts++;
    user = userId;
    if (first && initialTap != null) opened.add(initialTap!);
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGate?.future ?? authorized;
  }

  @override
  Future<bool> hasPermission() async => authorized;
  @override
  Future<String?> getToken() async {
    tokenReads++;
    return token;
  }

  @override
  void setForegroundEnabled(bool enabled) => this.enabled = enabled;
  @override
  Future<void> stop({bool invalidateToken = false}) async {
    user = null;
    enabled = false;
    if (invalidateToken) invalidations++;
  }

  @override
  Future<void> dispose() async {
    await tokens.close();
    await opened.close();
  }
}

Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late MutablePreferences preferences;
  late FakeDevices devices;
  late FakePushService service;
  late PushNotificationController controller;

  setUp(() {
    preferences = MutablePreferences();
    devices = FakeDevices(preferences);
    service = FakePushService();
    controller = PushNotificationController(preferences, devices, service);
  });
  tearDown(() => controller.dispose());

  test('push is off by default and survives map/copy/equality round trips', () {
    const defaults = NotificationPreferences(userId: 'user');
    expect(defaults.pushEnabled, isFalse);
    final enabled = defaults.copyWith(pushEnabled: true);
    expect(NotificationPreferences.fromMap(enabled.toMap()), enabled);
    expect(enabled, isNot(defaults));
    expect(enabled.stalledTaskEnabled, defaults.stalledTaskEnabled);
    expect(enabled.deadlineReminderEnabled, defaults.deadlineReminderEnabled);
    expect(enabled.recommendationEnabled, defaults.recommendationEnabled);
  });

  test(
    'startup and resume never request permission when push is disabled',
    () async {
      await Future.wait([controller.syncSession(), controller.syncSession()]);
      await controller.syncSession(resumed: true);
      expect(service.permissionRequests, 0);
      expect(service.tokenReads, 0);
      expect(devices.registrations, isEmpty);
      expect(service.starts, 1);
    },
  );

  test(
    'authorized preference registers once across repeated auth and resume',
    () async {
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'user',
        pushEnabled: true,
      );
      await Future.wait([controller.syncSession(), controller.syncSession()]);
      await controller.syncSession(resumed: true);
      expect(devices.registrations, ['user:token-one']);
      expect(service.starts, 1);
      expect(service.permissionRequests, 0);
      expect(service.enabled, isTrue);
    },
  );

  test(
    'denied permission restores the switch and does not save true or fetch a token',
    () async {
      service.authorized = false;
      final model = NotificationPreferencesViewModel(
        preferences,
        push: controller,
      );
      addTearDown(model.dispose);
      await model.initialize();
      await model.setPushEnabled(true);
      expect(model.preferences.pushEnabled, isFalse);
      expect(model.errorMessage, contains('permission was denied'));
      expect(preferences.saves, 0);
      expect(service.permissionRequests, 1);
      expect(service.tokenReads, 0);
      expect(devices.registrations, isEmpty);
    },
  );

  test('preference true is saved only after authorization completes', () async {
    service.permissionGate = Completer<bool>();
    final model = NotificationPreferencesViewModel(
      preferences,
      push: controller,
    );
    addTearDown(model.dispose);
    await model.initialize();
    final enabling = model.setPushEnabled(true);
    await flush();
    expect(model.isSaving, isTrue);
    expect(preferences.saves, 0);
    service.permissionGate!.complete(true);
    await enabling;
    expect(preferences.savedPreferences!.pushEnabled, isTrue);
    expect(devices.registrations, ['user:token-one']);
    expect(service.permissionRequests, 1);
  });

  test(
    'failed database save rolls back switch and unregisters the new device',
    () async {
      preferences.failSave = true;
      final model = NotificationPreferencesViewModel(
        preferences,
        push: controller,
      );
      addTearDown(model.dispose);
      await model.initialize();
      await model.setPushEnabled(true);
      expect(model.preferences.pushEnabled, isFalse);
      expect(devices.registrations, ['user:token-one']);
      expect(devices.removals, ['token-one']);
      expect(controller.isEnabled, isFalse);
      expect(model.errorMessage, isNotNull);
    },
  );

  test(
    'disable persists false and unregisters the device without prompting',
    () async {
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'user',
        pushEnabled: true,
      );
      await controller.syncSession();
      final model = NotificationPreferencesViewModel(
        preferences,
        push: controller,
      );
      addTearDown(model.dispose);
      await model.initialize();
      await model.setPushEnabled(false);
      expect(model.preferences.pushEnabled, isFalse);
      expect(preferences.savedPreferences!.pushEnabled, isFalse);
      expect(devices.removals, ['token-one']);
      expect(service.permissionRequests, 0);
      expect(service.enabled, isFalse);
    },
  );

  test(
    'token refresh registers the new token and retires the previous token',
    () async {
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'user',
        pushEnabled: true,
      );
      await controller.syncSession();
      service.token = 'token-two';
      service.tokens.add('token-two');
      service.tokens.add('token-two');
      await flush();
      expect(devices.registrations, ['user:token-one', 'user:token-two']);
      expect(devices.removals, ['token-one']);
    },
  );

  test(
    'logout cancels subscriptions and invalidates delivery to the old account',
    () async {
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'user',
        pushEnabled: true,
      );
      await controller.syncSession();
      preferences.user = null;
      await controller.syncSession();
      service.tokens.add('late-token');
      await flush();
      expect(service.tokens.hasListener, isFalse);
      expect(service.opened.hasListener, isFalse);
      expect(service.invalidations, 1);
      expect(service.enabled, isFalse);
      expect(devices.registrations, ['user:token-one']);
    },
  );

  test('account change registers only for the current learner', () async {
    preferences.savedPreferences = const NotificationPreferences(
      userId: 'user',
      pushEnabled: true,
    );
    await controller.syncSession();
    preferences.user = 'second';
    preferences.savedPreferences = const NotificationPreferences(
      userId: 'second',
      pushEnabled: true,
    );
    await controller.syncSession();
    expect(devices.registrations, ['user:token-one', 'second:token-one']);
    expect(service.invalidations, 1);
  });

  test(
    'late preference results cannot register for an account that signed out',
    () async {
      preferences.pendingPreferences = Completer<NotificationPreferences>();
      final first = controller.syncSession();
      await flush();
      preferences.user = null;
      final logout = controller.syncSession();
      preferences.pendingPreferences!.complete(
        const NotificationPreferences(userId: 'user', pushEnabled: true),
      );
      await first;
      await logout;
      expect(devices.registrations, isEmpty);
      expect(service.enabled, isFalse);
    },
  );

  test(
    'permission revoked in Android settings retires the active device on resume',
    () async {
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'user',
        pushEnabled: true,
      );
      await controller.syncSession();
      service.authorized = false;
      await controller.syncSession(resumed: true);
      expect(devices.removals, ['token-one']);
      expect(service.permissionRequests, 0);
      expect(service.enabled, isFalse);
    },
  );

  test(
    'duplicate taps and pushes for a different account are ignored',
    () async {
      final taps = <PushNotificationTap>[];
      final sub = controller.taps.listen(taps.add);
      addTearDown(sub.cancel);
      await controller.syncSession();
      service.opened.add(
        const PushNotificationTap(notificationId: 'one', userId: 'user'),
      );
      service.opened.add(
        const PushNotificationTap(notificationId: 'one', userId: 'user'),
      );
      service.opened.add(
        const PushNotificationTap(
          notificationId: 'two',
          userId: 'someone-else',
        ),
      );
      await flush();
      expect(taps.map((tap) => tap.notificationId), ['one']);
    },
  );

  test(
    'local identifiers are deterministic and malformed payloads are ignored',
    () {
    expect(pushNotificationId('hello'), 0x4f9f2cab);
      expect(
        pushNotificationId('notification-one'),
        isNot(pushNotificationId('notification-two')),
      );
      expect(
        pushNotificationId('notification-one'),
        inInclusiveRange(0, 0x7fffffff),
      );
      expect(
        PushNotificationTap.fromData({'notification_id': 7, 'user_id': 'user'}),
        isNull,
      );
      expect(PushNotificationTap.fromData({'notification_id': 'one'}), isNull);
    },
  );

  test(
    'unsupported desktop does not initialize Firebase or request permission',
    () async {
      service.supported = false;
      await controller.syncSession();
      expect(service.starts, 0);
      await expectLater(
        controller.setEnabled(true, requestPermission: true),
        throwsA(isA<Exception>()),
      );
      expect(service.permissionRequests, 0);
    },
  );

  testWidgets(
    'preferences keeps the three category switches and adds one push switch',
    (tester) async {
      final model = NotificationPreferencesViewModel(
        preferences,
        push: controller,
      );
      addTearDown(model.dispose);
      await tester.pumpWidget(
        MaterialApp(home: NotificationPreferencesScreen(viewModel: model)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile), findsNWidgets(4));
      expect(find.text('Push notifications'), findsOneWidget);
      expect(
        find.text('Receive notifications when SkillTrack is not open.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'push tap opens the existing inbox once and preserves its detail flow',
    (tester) async {
      await tester.pumpWidget(
        SkillTrackApp(
          projectRepository: FakeProjectRepository(),
          kanbanRepository: FakeKanbanRepository(),
          notificationRepository: preferences,
          pushController: controller,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('My Projects'), findsWidgets);
      const tap = PushNotificationTap(notificationId: 'one', userId: 'user');
      service.opened.add(tap);
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsWidgets);
      service.opened.add(tap);
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  test(
    'permission-dialog resume cannot undo a successfully saved opt-in',
    () async {
      preferences.pendingSave = Completer<NotificationPreferences>();
      final model = NotificationPreferencesViewModel(
        preferences,
        push: controller,
      );
      addTearDown(model.dispose);
      await model.initialize();
      final enabling = model.setPushEnabled(true);
      await flush();
      await controller.syncSession(resumed: true);
      preferences.pendingSave!.complete(
        const NotificationPreferences(userId: 'user', pushEnabled: true),
      );
      await enabling;
      expect(model.preferences.pushEnabled, isTrue);
      expect(controller.isEnabled, isTrue);
      expect(service.enabled, isTrue);
      expect(service.permissionRequests, 1);
    },
  );

  test(
    'failed device cleanup keeps push disabled after its preference was saved',
    () async {
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'user',
        pushEnabled: true,
      );
      await controller.syncSession();
      final model = NotificationPreferencesViewModel(
        preferences,
        push: controller,
      );
      addTearDown(model.dispose);
      await model.initialize();
      devices.fail = true;
      await model.setPushEnabled(false);
      expect(preferences.savedPreferences!.pushEnabled, isFalse);
      expect(model.preferences.pushEnabled, isFalse);
      expect(service.enabled, isFalse);
      devices.fail = false;
      await controller.syncSession(resumed: true);
      expect(devices.removals, ['token-one']);
    },
  );

  testWidgets('initial push tap waits until the existing router is mounted', (
    tester,
  ) async {
    service.initialTap = const PushNotificationTap(
      notificationId: 'initial',
      userId: 'user',
    );
    await tester.pumpWidget(
      SkillTrackApp(
        projectRepository: FakeProjectRepository(),
        kanbanRepository: FakeKanbanRepository(),
        notificationRepository: preferences,
        pushController: controller,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Notifications'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
