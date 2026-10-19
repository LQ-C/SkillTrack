import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/app/skill_track_app.dart';
import 'package:skilltrack/features/notifications/models/app_notification.dart';
import 'package:skilltrack/features/notifications/models/notification_change.dart';
import 'package:skilltrack/features/notifications/models/notification_context_type.dart';
import 'package:skilltrack/features/notifications/models/notification_type.dart';
import 'package:skilltrack/features/notifications/services/notification_realtime_service.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_badge_controller.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_list_view_model.dart';

import '../kanban/fake_repository.dart';
import '../projects/fake_project_repository.dart';
import 'fake_notification_repository.dart';

class FakeTransport implements NotificationRealtimeTransport {
  int starts = 0, stops = 0;
  String? userId;
  void Function(PostgresChangePayload)? onPayload;
  void Function(RealtimeSubscribeStatus)? onStatus;

  @override
  Future<void> subscribeForUser(
    String userId,
    void Function(PostgresChangePayload) onPayload,
    void Function(RealtimeSubscribeStatus) onStatus,
  ) async {
    starts++;
    this.userId = userId;
    this.onPayload = onPayload;
    this.onStatus = onStatus;
    onStatus(RealtimeSubscribeStatus.subscribed);
  }

  @override
  Future<void> unsubscribe() async {
    stops++;
    userId = null;
    onPayload = null;
    onStatus = null;
  }

  void emit(
    PostgresChangeEvent event, {
    Map<String, dynamic> newRecord = const {},
    Map<String, dynamic> oldRecord = const {},
  }) => onPayload?.call(
    PostgresChangePayload(
      schema: 'public',
      table: 'notifications',
      commitTimestamp: DateTime.now().toUtc(),
      eventType: event,
      newRecord: newRecord,
      oldRecord: oldRecord,
      errors: null,
    ),
  );
}

class CountingRepository extends FakeNotificationRepository {
  CountingRepository({super.currentUserId});
  int countCalls = 0;
  Completer<List<AppNotification>>? pendingLoad;

  @override
  Future<int> getUnreadCount() {
    countCalls++;
    return super.getUnreadCount();
  }

  @override
  Future<List<AppNotification>> getNotifications({
    int limit = 50,
    DateTime? before,
    String? beforeId,
  }) =>
      pendingLoad?.future ??
      super.getNotifications(limit: limit, before: before, beforeId: beforeId);
}

class MutableRepository extends CountingRepository {
  MutableRepository() : super(currentUserId: 'user');
  String? signedInUser = 'user';
  Completer<void>? pendingMarkAll;

  @override
  String? get currentUserId => signedInUser;

  @override
  Future<void> markAllAsRead() =>
      pendingMarkAll?.future ?? super.markAllAsRead();
}

AppNotification alert(
  String id, {
  bool read = false,
  String user = 'user',
  DateTime? date,
}) => AppNotification(
  id: id,
  userId: user,
  type: NotificationType.stalledTask,
  contextType: NotificationContextType.task,
  projectId: 'project',
  boardId: 'board',
  taskId: 'task',
  title: 'Task alert $id',
  message: 'Task needs attention',
  isRead: read,
  readAt: read ? DateTime.utc(2026, 10, 10) : null,
  createdAt: date ?? DateTime.utc(2026, 10, 10),
);

Future<void> flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'one channel per user; switching and logout remove the old channel',
    () async {
      final transport = FakeTransport();
      final service = NotificationRealtimeService(transport);
      await service.startForUser('user');
      await service.startForUser('user');
      expect(transport.starts, 1);
      final previousCallback = transport.onPayload!;
      final changes = <NotificationChange>[];
      final subscription = service.changes.listen(changes.add);
      await service.startForUser('other');
      expect(transport.starts, 2);
      expect(transport.stops, 1);
      previousCallback(
        PostgresChangePayload(
          schema: 'public',
          table: 'notifications',
          commitTimestamp: DateTime.now().toUtc(),
          eventType: PostgresChangeEvent.insert,
          newRecord: alert('stale').toMap(),
          oldRecord: const {},
          errors: null,
        ),
      );
      await flushEvents();
      expect(
        changes.where((change) => change.notificationId == 'stale'),
        isEmpty,
      );
      await service.stop();
      expect(transport.stops, 2);
      expect(service.activeUserId, isNull);
      await subscription.cancel();
      await service.dispose();
    },
  );

  test(
    'malformed and cross-user payloads are ignored; delete needs only ID',
    () async {
      final transport = FakeTransport();
      final service = NotificationRealtimeService(transport);
      final changes = <NotificationChange>[];
      final subscription = service.changes.listen(changes.add);
      await service.startForUser('user');
      transport.emit(
        PostgresChangeEvent.insert,
        newRecord: alert('other', user: 'other').toMap(),
      );
      transport.emit(
        PostgresChangeEvent.insert,
        newRecord: const {'id': 'bad', 'user_id': 'user'},
      );
      transport.emit(
        PostgresChangeEvent.delete,
        oldRecord: const {'id': 'deleted'},
      );
      await flushEvents();
      expect(changes.map((change) => change.notificationId), ['deleted']);
      await subscription.cancel();
      await service.dispose();
    },
  );

  test(
    'JSON-compatible payload values are parsed without strict type checks',
    () async {
      final transport = FakeTransport();
      final service = NotificationRealtimeService(transport);
      final changes = <NotificationChange>[];
      final subscription = service.changes.listen(changes.add);
      await service.startForUser('user');
      transport.emit(
        PostgresChangeEvent.insert,
        newRecord: {
          ...alert('42').toMap(),
          'id': 42,
          'created_at': DateTime.utc(2026, 10, 11),
        },
      );
      transport.emit(
        PostgresChangeEvent.delete,
        oldRecord: const {'id': 42, 'user_id': 'user'},
      );
      transport.emit(
        PostgresChangeEvent.delete,
        oldRecord: const {'id': 43, 'user_id': 'other'},
      );
      await flushEvents();
      expect(changes.map((change) => change.notificationId), ['42', '42']);
      expect(changes.first.notification!.createdAt, DateTime.utc(2026, 10, 11));
      await subscription.cancel();
      await service.dispose();
    },
  );

  test('insert, duplicate, update, delete and active filter', () async {
    final repo = CountingRepository(currentUserId: 'user')
      ..items.add(alert('old'));
    final transport = FakeTransport();
    final service = NotificationRealtimeService(transport);
    await service.startForUser('user');
    final badge = NotificationBadgeController(repo, service);
    await badge.startForUser('user');
    final model = NotificationListViewModel(
      repo,
      FakeProjectRepository(),
      FakeKanbanRepository(),
      badge,
      service,
    );
    await model.initialize();
    model.setFilter(NotificationListFilter.unread);
    final fresh = alert('new', date: DateTime.utc(2026, 10, 11));
    repo.items.add(fresh);
    transport.emit(PostgresChangeEvent.insert, newRecord: fresh.toMap());
    transport.emit(PostgresChangeEvent.insert, newRecord: fresh.toMap());
    await flushEvents();
    expect(model.allNotifications.map((item) => item.id), ['new', 'old']);
    expect(model.visibleNotifications.length, 2);
    expect(badge.unreadCount, 2);
    final readFresh = fresh.copyWith(
      isRead: true,
      readAt: DateTime.now().toUtc(),
    );
    repo.items[repo.items.indexWhere((item) => item.id == 'new')] = readFresh;
    transport.emit(PostgresChangeEvent.update, newRecord: readFresh.toMap());
    await flushEvents();
    expect(model.visibleNotifications.map((item) => item.id), ['old']);
    expect(model.allNotifications.first.isRead, isTrue);
    expect(badge.unreadCount, 1);
    repo.items.removeWhere((item) => item.id == 'old');
    transport.emit(PostgresChangeEvent.delete, oldRecord: const {'id': 'old'});
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(model.allNotifications.map((item) => item.id), ['new']);
    expect(badge.unreadCount, 0);
    model.dispose();
    badge.dispose();
    await service.dispose();
  });

  test(
    'read insert leaves badge unchanged; local read ignores its Realtime echo',
    () async {
      final repo = CountingRepository(currentUserId: 'user')
        ..items.add(alert('old'));
      final transport = FakeTransport();
      final service = NotificationRealtimeService(transport);
      await service.startForUser('user');
      final badge = NotificationBadgeController(repo, service);
      await badge.startForUser('user');
      final model = NotificationListViewModel(
        repo,
        FakeProjectRepository(),
        FakeKanbanRepository(),
        badge,
        service,
      );
      await model.initialize();
      transport.emit(
        PostgresChangeEvent.insert,
        newRecord: alert('read', read: true).toMap(),
      );
      await flushEvents();
      expect(badge.unreadCount, 1);
      expect(await model.markAsRead('old'), isTrue);
      expect(badge.unreadCount, 0);
      transport.emit(
        PostgresChangeEvent.update,
        newRecord: repo.items.first.toMap(),
      );
      await flushEvents();
      expect(badge.unreadCount, 0);
      expect(
        model.allNotifications.firstWhere((item) => item.id == 'old').isRead,
        isTrue,
      );
      model.dispose();
      badge.dispose();
      await service.dispose();
    },
  );

  test(
    'mark all clears count and duplicate deletes cannot make it negative',
    () async {
      final repo = CountingRepository(currentUserId: 'user')
        ..items.addAll([alert('one'), alert('two')]);
      final transport = FakeTransport();
      final service = NotificationRealtimeService(transport);
      await service.startForUser('user');
      final badge = NotificationBadgeController(repo, service);
      await badge.startForUser('user');
      final model = NotificationListViewModel(
        repo,
        FakeProjectRepository(),
        FakeKanbanRepository(),
        badge,
        service,
      );
      await model.initialize();
      await model.markAllAsRead();
      expect(badge.unreadCount, 0);
      expect(model.allNotifications.every((item) => item.isRead), isTrue);
      transport.emit(
        PostgresChangeEvent.delete,
        oldRecord: const {'id': 'one'},
      );
      transport.emit(
        PostgresChangeEvent.delete,
        oldRecord: const {'id': 'one'},
      );
      await flushEvents();
      expect(badge.unreadCount, 0);
      model.dispose();
      badge.dispose();
      await service.dispose();
    },
  );

  test('initial fetch merges simultaneous insert without duplicates', () async {
    final repo = CountingRepository(currentUserId: 'user')
      ..pendingLoad = Completer<List<AppNotification>>();
    final transport = FakeTransport();
    final service = NotificationRealtimeService(transport);
    await service.startForUser('user');
    final badge = NotificationBadgeController(repo, service);
    await badge.startForUser('user');
    final model = NotificationListViewModel(
      repo,
      FakeProjectRepository(),
      FakeKanbanRepository(),
      badge,
      service,
    );
    final loading = model.initialize();
    await flushEvents();
    final fresh = alert('fresh');
    transport.emit(PostgresChangeEvent.insert, newRecord: fresh.toMap());
    repo.pendingLoad!.complete([fresh]);
    await loading;
    expect(model.allNotifications.map((item) => item.id), ['fresh']);
    model.dispose();
    badge.dispose();
    await service.dispose();
  });

  test(
    'a buffered Realtime update wins over an older fetch snapshot',
    () async {
      final repo = CountingRepository(currentUserId: 'user')
        ..pendingLoad = Completer<List<AppNotification>>();
      final transport = FakeTransport();
      final service = NotificationRealtimeService(transport);
      await service.startForUser('user');
      final badge = NotificationBadgeController(repo, service);
      await badge.startForUser('user');
      final model = NotificationListViewModel(
        repo,
        FakeProjectRepository(),
        FakeKanbanRepository(),
        badge,
        service,
      );
      final loading = model.initialize();
      await flushEvents();
      final stale = alert('same');
      final updated = stale.copyWith(
        isRead: true,
        readAt: DateTime.now().toUtc(),
      );
      transport.emit(PostgresChangeEvent.update, newRecord: updated.toMap());
      repo.pendingLoad!.complete([stale]);
      await loading;
      expect(model.allNotifications.single.isRead, isTrue);
      model.dispose();
      badge.dispose();
      await service.dispose();
    },
  );

  test('Realtime failure retains list; resume requests one refresh', () async {
    final repo = CountingRepository(currentUserId: 'user')
      ..items.add(alert('old'));
    final transport = FakeTransport();
    final service = NotificationRealtimeService(transport);
    await service.startForUser('user');
    final badge = NotificationBadgeController(repo, service);
    await badge.startForUser('user');
    final model = NotificationListViewModel(
      repo,
      FakeProjectRepository(),
      FakeKanbanRepository(),
      badge,
      service,
    );
    await model.initialize();
    transport.onStatus?.call(RealtimeSubscribeStatus.channelError);
    expect(service.isConnected, isFalse);
    expect(model.allNotifications.length, 1);
    await service.startForUser('user');
    expect(transport.starts, 2);
    expect(model.allNotifications.length, 1);
    repo.items.add(alert('new', date: DateTime.utc(2026, 10, 11)));
    service.requestSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(model.allNotifications.map((item) => item.id), ['new', 'old']);
    model.dispose();
    badge.dispose();
    await service.dispose();
  });

  test('unknown updates debounce one exact badge refresh', () async {
    final repo = CountingRepository(currentUserId: 'user')
      ..items.add(alert('old'));
    final transport = FakeTransport();
    final service = NotificationRealtimeService(transport);
    await service.startForUser('user');
    final badge = NotificationBadgeController(repo, service);
    await badge.startForUser('user');
    expect(repo.countCalls, 1);
    final read = alert('old', read: true);
    repo.items[0] = read;
    transport.emit(PostgresChangeEvent.update, newRecord: read.toMap());
    transport.emit(PostgresChangeEvent.update, newRecord: read.toMap());
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(repo.countCalls, 2);
    expect(badge.unreadCount, 0);
    badge.dispose();
    await service.dispose();
  });

  test(
    'channel reconnection refreshes list and badge without another channel',
    () async {
      final repo = CountingRepository(currentUserId: 'user')
        ..items.add(alert('old'));
      final transport = FakeTransport();
      final service = NotificationRealtimeService(transport);
      await service.startForUser('user');
      final badge = NotificationBadgeController(repo, service);
      await badge.startForUser('user');
      final model = NotificationListViewModel(
        repo,
        FakeProjectRepository(),
        FakeKanbanRepository(),
        badge,
        service,
      );
      await model.initialize();
      repo.items.add(alert('new', date: DateTime.utc(2026, 10, 11)));
      transport.onStatus?.call(RealtimeSubscribeStatus.channelError);
      transport.onStatus?.call(RealtimeSubscribeStatus.subscribed);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(transport.starts, 1);
      expect(model.allNotifications.map((item) => item.id), ['new', 'old']);
      expect(badge.unreadCount, 2);
      expect(repo.countCalls, 2);
      model.dispose();
      badge.dispose();
      await service.dispose();
    },
  );

  test('new Realtime rows keep older pages loadable', () async {
    final newest = DateTime.utc(2026, 10, 11);
    final repo = CountingRepository(currentUserId: 'user')
      ..items.addAll(
        List.generate(
          51,
          (index) =>
              alert('$index', date: newest.subtract(Duration(minutes: index))),
        ),
      );
    final transport = FakeTransport();
    final service = NotificationRealtimeService(transport);
    await service.startForUser('user');
    final badge = NotificationBadgeController(repo, service);
    await badge.startForUser('user');
    final model = NotificationListViewModel(
      repo,
      FakeProjectRepository(),
      FakeKanbanRepository(),
      badge,
      service,
    );
    await model.initialize();
    expect(model.allNotifications.length, 50);
    expect(model.hasMore, isTrue);
    final fresh = alert('fresh', date: newest.add(const Duration(minutes: 1)));
    repo.items.add(fresh);
    transport.emit(PostgresChangeEvent.insert, newRecord: fresh.toMap());
    await flushEvents();
    expect(model.allNotifications.first.id, 'fresh');
    await model.loadMore();
    expect(model.allNotifications.length, 52);
    expect(model.allNotifications.last.id, '50');
    expect(model.hasMore, isFalse);
    model.dispose();
    badge.dispose();
    await service.dispose();
  });

  test(
    'logout clears cached list and badge; disposed listeners ignore events',
    () async {
      final repo = CountingRepository(currentUserId: 'user')
        ..items.add(alert('old'));
      final transport = FakeTransport();
      final service = NotificationRealtimeService(transport);
      await service.startForUser('user');
      final badge = NotificationBadgeController(repo, service);
      await badge.startForUser('user');
      final model = NotificationListViewModel(
        repo,
        FakeProjectRepository(),
        FakeKanbanRepository(),
        badge,
        service,
      );
      await model.initialize();
      await service.stop();
      await flushEvents();
      expect(model.allNotifications, isEmpty);
      expect(badge.unreadCount, 0);
      model.dispose();
      badge.dispose();
      await service.startForUser('user');
      transport.emit(
        PostgresChangeEvent.insert,
        newRecord: alert('late').toMap(),
      );
      await flushEvents();
      expect(badge.unreadCount, 0);
      await service.dispose();
    },
  );

  test('a failed read-all request cannot restore previous-user rows', () async {
    final repo = MutableRepository()
      ..items.add(alert('old'))
      ..pendingMarkAll = Completer<void>();
    final transport = FakeTransport();
    final service = NotificationRealtimeService(transport);
    await service.startForUser('user');
    final badge = NotificationBadgeController(repo, service);
    await badge.startForUser('user');
    final model = NotificationListViewModel(
      repo,
      FakeProjectRepository(),
      FakeKanbanRepository(),
      badge,
      service,
    );
    await model.initialize();
    final marking = model.markAllAsRead();
    repo.signedInUser = null;
    await service.stop();
    await flushEvents();
    repo.pendingMarkAll!.completeError(StateError('offline'));
    await marking;
    expect(model.allNotifications, isEmpty);
    expect(badge.unreadCount, 0);
    model.dispose();
    badge.dispose();
    await service.dispose();
  });

  testWidgets('app resume syncs once and auth logout removes channel', (
    tester,
  ) async {
    final repo = MutableRepository()..items.add(alert('old'));
    final transport = FakeTransport();
    final service = NotificationRealtimeService(transport);
    final authEvents = StreamController<Object?>.broadcast();
    await tester.pumpWidget(
      SkillTrackApp(
        projectRepository: FakeProjectRepository(),
        kanbanRepository: FakeKanbanRepository(),
        notificationRepository: repo,
        realtimeService: service,
        authEvents: authEvents.stream,
      ),
    );
    await tester.pumpAndSettle();
    expect(transport.starts, 1);
    expect(repo.countCalls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(transport.starts, 1);
    expect(repo.countCalls, 2);
    repo.signedInUser = null;
    authEvents.add(null);
    await tester.pumpAndSettle();
    expect(transport.stops, 1);
    expect(service.activeUserId, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await authEvents.close();
  });

  testWidgets('resume after a user switch initializes the new badge', (
    tester,
  ) async {
    final repo = MutableRepository()..items.add(alert('old'));
    final transport = FakeTransport();
    final service = NotificationRealtimeService(transport);
    await tester.pumpWidget(
      SkillTrackApp(
        projectRepository: FakeProjectRepository(),
        kanbanRepository: FakeKanbanRepository(),
        notificationRepository: repo,
        realtimeService: service,
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.countCalls, 1);
    repo.signedInUser = 'other';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(service.activeUserId, 'other');
    expect(transport.starts, 2);
    expect(transport.stops, 1);
    expect(repo.countCalls, greaterThan(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Realtime insert updates date groups on the open screen', (
    tester,
  ) async {
    final repo = CountingRepository(currentUserId: 'user');
    final transport = FakeTransport();
    final service = NotificationRealtimeService(transport);
    await tester.pumpWidget(
      SkillTrackApp(
        projectRepository: FakeProjectRepository(),
        kanbanRepository: FakeKanbanRepository(),
        notificationRepository: repo,
        realtimeService: service,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    final today = DateTime.now();
    final yesterday = today.subtract(const Duration(days: 1));
    transport.emit(
      PostgresChangeEvent.insert,
      newRecord: alert('yesterday', date: yesterday.toUtc()).toMap(),
    );
    transport.emit(
      PostgresChangeEvent.insert,
      newRecord: alert('today', date: today.toUtc()).toMap(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Task alert today'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('equal timestamps do not skip notifications between pages', () async {
    final repo = CountingRepository(currentUserId: 'user')
      ..items.addAll(
        List.generate(121, (i) => alert(i.toString().padLeft(3, '0'))),
      );
    final badge = NotificationBadgeController(repo);
    final model = NotificationListViewModel(
      repo,
      FakeProjectRepository(),
      FakeKanbanRepository(),
      badge,
    );
    addTearDown(model.dispose);
    addTearDown(badge.dispose);
    await model.initialize();
    await model.loadMore();
    await model.loadMore();
    expect(model.allNotifications, hasLength(121));
    expect(model.allNotifications.map((n) => n.id).toSet(), hasLength(121));
    expect(model.hasMore, isFalse);
  });

  test(
    'refresh invalidates an older page without leaving loadingMore stuck',
    () async {
      final repo = CountingRepository(currentUserId: 'user')
        ..items.addAll(
          List.generate(51, (i) => alert(i.toString().padLeft(3, '0'))),
        );
      final badge = NotificationBadgeController(repo);
      final model = NotificationListViewModel(
        repo,
        FakeProjectRepository(),
        FakeKanbanRepository(),
        badge,
      );
      addTearDown(model.dispose);
      addTearDown(badge.dispose);
      await model.initialize();
      final gate = Completer<List<AppNotification>>();
      repo.pendingLoad = gate;
      final older = model.loadMore();
      repo.pendingLoad = null;
      await model.refresh();
      expect(model.isLoadingMore, isFalse);
      gate.complete([alert('stale')]);
      await older;
      expect(model.allNotifications.any((n) => n.id == 'stale'), isFalse);
      await model.loadMore();
      expect(model.allNotifications, hasLength(51));
    },
  );

  test('retained inbox reloads for another account after reset', () async {
    final repo = MutableRepository()
      ..items.addAll([alert('old'), alert('new', user: 'second')]);
    final service = NotificationRealtimeService(FakeTransport());
    final badge = NotificationBadgeController(repo, service);
    final model = NotificationListViewModel(
      repo,
      FakeProjectRepository(),
      FakeKanbanRepository(),
      badge,
      service,
    );
    await model.initialize();
    await flushEvents();
    expect(model.allNotifications.single.id, 'old');
    await service.stop();
    await flushEvents();
    repo.signedInUser = 'second';
    await service.startForUser('second');
    await flushEvents();
    expect(model.allNotifications.single.id, 'new');
    model.dispose();
    badge.dispose();
    await service.dispose();
  });
}
