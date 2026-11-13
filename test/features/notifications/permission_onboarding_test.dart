import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/notifications/services/notification_installation_service.dart';
import 'package:skilltrack/features/notifications/models/notification_preferences.dart';
import 'package:skilltrack/features/notifications/viewmodels/push_notification_controller.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_preferences_view_model.dart';
import 'package:skilltrack/features/notifications/widgets/push_permission_onboarding.dart';
import 'package:skilltrack/features/notifications/views/notification_preferences_screen.dart';
import 'push_notification_test.dart'
    show MutablePreferences, FakeDevices, FakePushService;

class Installation implements NotificationInstallationService {
  bool granted = false,
      canRequest = true,
      handled = false,
      supportedValue = true,
      fail = false;
  int reads = 0, requests = 0, settings = 0;
  final optedOut = <String>{};
  @override
  bool get supported => supportedValue;
  @override
  Future<NotificationInstallation> read(String user) async {
    reads++;
    if (fail) throw StateError('disk');
    return NotificationInstallation(
      granted: granted,
      canRequest: canRequest,
      handled: handled,
      optedOut: optedOut.contains(user),
    );
  }

  @override
  Future<void> markHandled() async {
    handled = true;
  }

  @override
  Future<void> markRequested() async {
    requests++;
    handled = true;
  }

  @override
  Future<void> rememberChoice(String user, bool enabled) async {
    handled = true;
    if (enabled) {
      optedOut.remove(user);
    } else {
      optedOut.add(user);
    }
  }

  @override
  Future<void> openSettings() async {
    settings++;
  }
}

class PermissionService extends FakePushService {
  PermissionService(this.installation) {
    authorized = installation.granted;
  }
  final Installation installation;
  bool allow = true;
  bool failPermission = false, failToken = false;
  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    if (failPermission) throw StateError('permission unavailable');
    final result = await (permissionGate?.future ?? Future.value(allow));
    authorized = result;
    installation.granted = result;
    return result;
  }

  @override
  Future<String?> getToken() async {
    if (failToken) throw StateError('token unavailable');
    return super.getToken();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MutablePreferences preferences;
  late FakeDevices devices;
  late Installation install;
  late PermissionService service;
  late PushNotificationController controller;
  void setup() {
    preferences = MutablePreferences();
    devices = FakeDevices(preferences);
    install = Installation();
    service = PermissionService(install);
    controller = PushNotificationController(
      preferences,
      devices,
      service,
      installation: install,
    );
  }

  setUp(setup);
  tearDown(() => controller.dispose());
  test(
    'first authenticated installation offers explanation without requesting or saving',
    () async {
      final offer = await controller.prepareOnboarding();
      expect(offer, isNotNull);
      expect(offer!.settings, false);
      expect(service.permissionRequests, 0);
      expect(preferences.saves, 0);
      expect(devices.registrations, isEmpty);
    },
  );
  test(
    'granted permission and enabled preference registers without explanation or permission request',
    () async {
      install.granted = service.authorized = true;
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'user',
        pushEnabled: true,
      );
      expect(await controller.prepareOnboarding(), isNull);
      expect(devices.registrations, ['user:token-one']);
      expect(service.permissionRequests, 0);
    },
  );
  test(
    'Not Now persists across controller recreation and account changes without saving preferences',
    () async {
      final offer = (await controller.prepareOnboarding())!;
      controller.dismissOffer(offer);
      expect(await controller.prepareOnboarding(), isNull);
      expect(preferences.saves, 0);
      await controller.dispose();
      service = PermissionService(install);
      controller = PushNotificationController(
        preferences,
        devices,
        service,
        installation: install,
      );
      expect(await controller.prepareOnboarding(), isNull);
      preferences.user = 'second';
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'second',
      );
      expect(await controller.prepareOnboarding(), isNull);
      expect(service.permissionRequests, 0);
    },
  );
  test(
    'explicit consent saves only after device registration and preserves categories',
    () async {
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'user',
        deadlineReminderEnabled: false,
      );
      final offer = (await controller.prepareOnboarding())!;
      await controller.acceptOffer(offer);
      expect(service.permissionRequests, 1);
      expect(install.requests, 1);
      expect(devices.registrations, ['user:token-one']);
      expect(preferences.savedPreferences!.pushEnabled, true);
      expect(preferences.savedPreferences!.deadlineReminderEnabled, false);
    },
  );
  test(
    'granted permission and disabled preference requires consent; switching account never asks Android again',
    () async {
      install.granted = service.authorized = true;
      final offer = (await controller.prepareOnboarding())!;
      expect(preferences.saves, 0);
      await controller.acceptOffer(offer);
      preferences.user = 'second';
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'second',
      );
      await controller.syncSession();
      expect(await controller.prepareOnboarding(), isNull);
      expect(service.permissionRequests, 0);
      expect(preferences.savedPreferences!.pushEnabled, false);
    },
  );
  test('new installation does its own check even if account exists', () async {
    install.handled = true;
    expect(await controller.prepareOnboarding(), isNull);
    await controller.dispose();
    install = Installation();
    service = PermissionService(install);
    controller = PushNotificationController(
      preferences,
      devices,
      service,
      installation: install,
    );
    expect(await controller.prepareOnboarding(), isNotNull);
  });
  test(
    'previous denial offers Settings and Settings return registers after explicit consent',
    () async {
      install.canRequest = false;
      final offer = (await controller.prepareOnboarding())!;
      expect(offer.settings, true);
      await controller.acceptOffer(offer);
      expect(install.settings, 1);
      expect(service.permissionRequests, 0);
      expect(preferences.saves, 0);
      install.granted = service.authorized = true;
      await controller.resumePermissionOnboarding();
      await controller.resumePermissionOnboarding();
      expect(preferences.savedPreferences!.pushEnabled, true);
      expect(preferences.saves, 1);
      expect(devices.registrations, ['user:token-one']);
      expect(service.permissionRequests, 0);
    },
  );
  test(
    'Settings return without grant leaves preference unchanged and does not reopen Settings',
    () async {
      install.canRequest = false;
      final offer = (await controller.prepareOnboarding())!;
      await controller.acceptOffer(offer);
      await controller.resumePermissionOnboarding();
      expect(preferences.saves, 0);
      expect(install.settings, 1);
      expect(await controller.prepareOnboarding(), isNull);
    },
  );
  test(
    'retry is available only on explicit action when Android permits',
    () async {
      install.canRequest = true;
      service.allow = false;
      await controller.acceptOffer((await controller.prepareOnboarding())!);
      expect(service.permissionRequests, 1);
      expect(preferences.saves, 0);
      expect(await controller.prepareOnboarding(), isNull);
      service.allow = true;
      await controller.setEnabled(true, requestPermission: true);
      expect(service.permissionRequests, 2);
      service.authorized = install.granted = false;
      install.canRequest = false;
      await expectLater(
        controller.setEnabled(true, requestPermission: true),
        throwsA(anything),
      );
      expect(service.permissionRequests, 2);
    },
  );
  test(
    'manual explicit opt-out is remembered and never silently overridden',
    () async {
      install.granted = service.authorized = true;
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'user',
        pushEnabled: true,
      );
      final vm = NotificationPreferencesViewModel(
        preferences,
        push: controller,
      );
      addTearDown(vm.dispose);
      await vm.initialize();
      await vm.setPushEnabled(false);
      expect(install.optedOut, contains('user'));
      expect(preferences.savedPreferences!.pushEnabled, false);
      expect(await controller.prepareOnboarding(), isNull);
      expect(service.permissionRequests, 0);
    },
  );
  test(
    'duplicate checks and accept callbacks request and save only once',
    () async {
      final results = await Future.wait([
        controller.prepareOnboarding(),
        controller.prepareOnboarding(),
      ]);
      expect(results.whereType<PushPermissionOffer>().length, 1);
      final offer = results.whereType<PushPermissionOffer>().single;
      await Future.wait([
        controller.acceptOffer(offer),
        controller.acceptOffer(offer),
      ]);
      expect(service.permissionRequests, 1);
      expect(preferences.saves, 1);
    },
  );
  test(
    'account switch during prompt or permission request cannot enable another account',
    () async {
      final offer = (await controller.prepareOnboarding())!;
      service.permissionGate = Completer<bool>();
      final enabling = controller.acceptOffer(offer);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      preferences.user = 'second';
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'second',
      );
      final switching = controller.syncSession();
      service.permissionGate!.complete(true);
      await enabling;
      await switching;
      expect(preferences.saves, 0);
      expect(devices.registrations, isEmpty);
      expect(controller.isOfferCurrent(offer), false);
      await controller.acceptOffer(offer);
      expect(preferences.saves, 0);
    },
  );
  test('signout while Settings is open clears pending consent', () async {
    install.canRequest = false;
    await controller.acceptOffer((await controller.prepareOnboarding())!);
    preferences.user = null;
    await controller.syncSession();
    install.granted = service.authorized = true;
    await controller.resumePermissionOnboarding();
    expect(preferences.saves, 0);
    expect(devices.registrations, isEmpty);
  });
  for (final failure in [
    'permission',
    'registration',
    'token',
    'preferences',
  ]) {
    test('$failure failure leaves preference off and login usable', () async {
      final offer = (await controller.prepareOnboarding())!;
      service.failPermission = failure == 'permission';
      service.failToken = failure == 'token';
      devices.fail = failure == 'registration';
      preferences.failSave = failure == 'preferences';
      await controller.acceptOffer(offer);
      expect(preferences.currentUserId, 'user');
      expect(preferences.savedPreferences!.pushEnabled, false);
      expect(controller.errorMessage, isNotNull);
      expect(service.enabled, false);
    });
  }
  test(
    'installation-read failure and unsupported platforms never block login',
    () async {
      install.fail = true;
      expect(await controller.prepareOnboarding(), isNull);
      expect(preferences.currentUserId, 'user');
      install.supportedValue = false;
      expect(await controller.prepareOnboarding(), isNull);
      expect(service.permissionRequests, 0);
    },
  );
  test('disposal during permission request cannot save or register', () async {
    final offer = (await controller.prepareOnboarding())!;
    service.permissionGate = Completer<bool>();
    final enabling = controller.acceptOffer(offer);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final disposal = controller.dispose();
    service.permissionGate!.complete(true);
    await enabling;
    await disposal;
    expect(preferences.saves, 0);
    expect(devices.registrations, isEmpty);
  });
  testWidgets(
    'explanation appears after main frame and Not Now keeps main available',
    (tester) async {
      await controller.dispose();
      setup(); // Queue belongs to widget async zone.
      await tester.pumpWidget(
        MaterialApp(
          home: PushPermissionOnboarding(
            controller: controller,
            child: const Scaffold(body: Text('Main screen')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Enable Notifications'), findsOneWidget);
      expect(service.permissionRequests, 0);
      await tester.tap(find.text('Not Now'));
      await tester.pumpAndSettle();
      expect(find.text('Main screen'), findsOneWidget);
      expect(preferences.saves, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('permission failure returns to usable main screen', (
    tester,
  ) async {
    await controller.dispose();
    setup();
    service.allow = false;
    await tester.pumpWidget(
      MaterialApp(
        home: PushPermissionOnboarding(
          controller: controller,
          child: const Scaffold(body: Text('Main screen')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable Notifications'));
    await tester.pumpAndSettle();
    expect(find.text('Main screen'), findsOneWidget);
    expect(preferences.savedPreferences!.pushEnabled, false);
    expect(find.textContaining('permission was denied'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('manual preferences retain toggle and offer Android Settings', (
    tester,
  ) async {
    await controller.dispose();
    setup();
    install.canRequest = false;
    final vm = NotificationPreferencesViewModel(preferences, push: controller);
    addTearDown(vm.dispose);
    await tester.pumpWidget(
      MaterialApp(home: NotificationPreferencesScreen(viewModel: vm)),
    );
    await tester.pumpAndSettle();
    await vm.setPushEnabled(true);
    await tester.pumpAndSettle();
    expect(find.textContaining('permission is off'), findsWidgets);
    await tester.tap(find.text('Open Android Notification Settings'));
    await tester.pumpAndSettle();
    expect(install.settings, 1);
    expect(service.permissionRequests, 0);
    expect(preferences.savedPreferences!.pushEnabled, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('signed-out installation never prepares an explanation', () async {
    preferences.user = null;
    expect(await controller.prepareOnboarding(), isNull);
    expect(service.permissionRequests, 0);
    expect(install.reads, 0);
  });
  test(
    'account changes invalidate an outstanding explanation before accepting it',
    () async {
      final offer = (await controller.prepareOnboarding())!;
      preferences.user = 'second';
      preferences.savedPreferences = const NotificationPreferences(
        userId: 'second',
      );
      await controller.syncSession();
      expect(controller.isOfferCurrent(offer), false);
      expect(controller.offer, isNull);
      await controller.acceptOffer(offer);
      expect(service.permissionRequests, 0);
      expect(preferences.saves, 0);
    },
  );
  testWidgets(
    'Settings resume refreshes permission guidance without silently enabling account',
    (tester) async {
      await controller.dispose();
      setup();
      install.handled = true;
      install.canRequest = false;
      final vm = NotificationPreferencesViewModel(
        preferences,
        push: controller,
      );
      addTearDown(vm.dispose);
      await tester.pumpWidget(
        MaterialApp(home: NotificationPreferencesScreen(viewModel: vm)),
      );
      await tester.pumpAndSettle();
      expect(vm.permissionMessage, contains('permission is off'));
      install.granted = service.authorized = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(vm.permissionMessage, contains('permission is allowed'));
      expect(preferences.savedPreferences!.pushEnabled, false);
      expect(preferences.saves, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'platform service reads and writes installation state without Firebase or backend calls',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            AndroidNotificationInstallationService.channel,
            (call) async {
              calls.add(call);
              if (call.method == 'status') {
                return {
                  'granted': false,
                  'canRequest': false,
                  'handled': true,
                  'optedOut': true,
                };
              }
              return null;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              AndroidNotificationInstallationService.channel,
              null,
            ),
      );
      final platform = AndroidNotificationInstallationService();
      final state = await platform.read('user');
      expect(state.handled, true);
      expect(state.canRequest, false);
      expect(state.optedOut, true);
      await platform.markHandled();
      await platform.markRequested();
      await platform.rememberChoice('user', false);
      await platform.openSettings();
      expect(calls.map((c) => c.method), [
        'status',
        'handled',
        'requested',
        'choice',
        'settings',
      ]);
    },
  );
}
