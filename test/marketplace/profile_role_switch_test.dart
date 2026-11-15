import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/app/marketplace_dependencies.dart';
import 'package:skilltrack/app/views/main_module_shell.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/features/dashboard/repositories/dashboard_repository.dart';
import 'package:skilltrack/features/dashboard/viewmodels/dashboard_view_model.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/viewmodels/content_library_view_model.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_badge_controller.dart';
import 'package:skilltrack/features/profile/viewmodels/profile_view_model.dart';
import 'package:skilltrack/features/tutor_management/models/tutor_models.dart';
import 'package:skilltrack/features/tutor_management/viewmodels/explore_mentors_view_model.dart';
import '../app/views/main_module_shell_test.dart' show tab;
import '../features/notifications/fake_notification_repository.dart';
import '../features/projects/fake_project_repository.dart';
import '../features/kanban/fake_repository.dart';
import 'session_integration_test.dart'
    show first, second, token, user, MemoryPkce;
import 'content_test.dart' show FakeContentRepository, sample;
import 'explore_loading_test.dart' show LoadingTutors;
import 'tutor_management_test.dart' show tutorProfile, mentor;

Map<String, dynamic> profile(String role, {String id = first}) => {
  'id': id,
  'full_name': 'Role Fixture',
  'date_of_birth': '2000-01-01',
  'role': role,
  'bio': 'Keep my data',
};

class ProfileBackend {
  Map<String, dynamic> row = profile('student');
  bool fail = false;
  Completer<Map<String, dynamic>>? pending;
  final requests = <http.Request>[];
  late final client = SupabaseClient(
    'https://fixture.supabase.co',
    'fixture-key',
    authOptions: AuthClientOptions(
      autoRefreshToken: false,
      pkceAsyncStorage: MemoryPkce(),
    ),
    httpClient: MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/token')) {
        final id = jsonDecode(request.body)['email'] == 'second@example.test'
            ? second
            : first;
        return http.Response(
          jsonEncode({
            'access_token': token(id),
            'refresh_token': 'fixture-refresh',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': user(id),
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/logout')) return http.Response('{}', 200);
      if (request.url.path == '/rest/v1/profiles') {
        if (request.method == 'PATCH') {
          if (fail) {
            return http.Response(
              jsonEncode({'message': 'fixture failure', 'code': '23514'}),
              400,
            );
          }
          row = pending == null
              ? {...row, ...jsonDecode(request.body) as Map<String, dynamic>}
              : await pending!.future;
        }
        return http.Response(
          jsonEncode(row),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      throw StateError('Unexpected request');
    }),
  );
  late final accounts = AccountService(client);
  Future<void> start() => accounts.signIn('first@example.test', 'Fixture1!');
  int get writes => requests.where((r) => r.method == 'PATCH').length;
}

// Shared fixture data mimics confirmed server results, not unsaved form values.
class RoleAccounts extends AccountService {
  @override
  String? userId = first;
  final sessions = StreamController<String?>.broadcast(sync: true);
  final changes = StreamController<String>.broadcast(sync: true);
  @override
  Stream<String?> get userChanges => sessions.stream;
  @override
  Stream<String> get profileChanges => changes.stream;
  @override
  String? get email => 'fixture@example.test';
  @override
  bool get emailVerified => true;
  Map<String, dynamic> row = profile('student');
  bool fail = false;
  int saves = 0;
  @override
  Future<Map<String, dynamic>> loadProfile() async => Map.of(row);
  @override
  Future<Map<String, dynamic>> saveProfile(
    String name,
    String birthDate,
    String role,
    String bio,
  ) async {
    saves++;
    if (fail) throw StateError('offline');
    row = {
      ...row,
      'full_name': name,
      'date_of_birth': birthDate,
      'role': role,
      'bio': bio,
    };
    changes.add(userId!);
    return Map.of(row);
  }

  void confirmed(String role) {
    row = profile(role);
    changes.add(userId!);
  }

  Future<void> close() async {
    await sessions.close();
    await changes.close();
  }
}

class RoleContent extends FakeContentRepository {
  RoleContent(this.accounts);
  final RoleAccounts accounts;
  Completer<List<LearningResource>>? pending;
  @override
  String get userId => accounts.userId!;
  @override
  Future<({bool mentor, bool publisher})> permissions() async {
    final mentor = accounts.row['role'] == 'mentor';
    return (mentor: mentor, publisher: mentor);
  }

  @override
  Future<List<LearningResource>> list({
    required bool mine,
    required String search,
    String? category,
    String? level,
    String? kind,
    required int offset,
  }) async {
    reads++;
    if (pending != null) return pending!.future;
    return [];
  }
}

class RoleTutors extends LoadingTutors {
  RoleTutors(this.accounts) {
    userId = first;
    own = tutorProfile('approved');
  }
  final RoleAccounts accounts;
  @override
  Future<String> role() async => accounts.row['role'] as String;
}

class RoleDashboard extends DashboardRepository {
  RoleDashboard(this.accounts);
  final RoleAccounts accounts;
  @override
  String? get userId => accounts.userId;
  @override
  Stream<String?> get userChanges => accounts.userChanges;
  int projectReads = 0, sessionReads = 0;
  @override
  Future<DashboardProjects> projects(DateTime now) async {
    projectReads++;
    return DashboardProjects(0, 0, 0, []);
  }

  @override
  Future<MentorshipSession?> session(DateTime now) async {
    sessionReads++;
    return null;
  }
}

Future<void> settleRequests() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('authorised profile save', () {
    late ProfileBackend backend;
    late ProfileViewModel vm;
    late List<String> events;
    late StreamSubscription<String> subscription;
    setUp(() async {
      backend = ProfileBackend();
      await backend.start();
      expect(
        await backend.accounts.loadProfile(),
        containsPair('role', 'student'),
      );
      vm = ProfileViewModel(backend.accounts, backend.accounts);
      await vm.load();
      expect(vm.profile?.role, 'student', reason: vm.message);
      events = [];
      subscription = backend.accounts.profileChanges.listen(events.add);
    });
    tearDown(() async {
      vm.dispose();
      await subscription.cancel();
      await backend.client.dispose();
    });
    test(
      'both directions use owned profile update and authoritative result only',
      () async {
        await vm.save(' Mentor ', '2000-01-01', 'mentor', ' bio ');
        expect(vm.profile?.role, 'mentor');
        expect(vm.profile?.name, 'Mentor');
        await vm.save('Student', '2000-01-01', 'student', 'retained');
        expect(vm.profile?.role, 'student');
        expect(events, [first, first]);
        final writes = backend.requests.where((r) => r.method == 'PATCH');
        expect(writes, hasLength(2));
        for (final r in writes) {
          expect(r.url.path, '/rest/v1/profiles');
          expect(r.url.queryParameters['id'], 'eq.$first');
          expect((jsonDecode(r.body) as Map).keys.toSet(), {
            'full_name',
            'date_of_birth',
            'role',
            'bio',
          });
        }
        expect(
          backend.requests.any(
            (r) =>
                r.url.path.contains('/rpc/') || r.url.path.contains('payments'),
          ),
          false,
        );
      },
    );
    test(
      'failed save retains confirmed role, does not publish event, and retry succeeds',
      () async {
        backend.fail = true;
        await vm.save('Fixture', '2000-01-01', 'mentor', 'draft');
        expect(vm.profile?.role, 'student');
        expect(vm.error, true);
        expect(vm.message, isNotNull);
        expect(vm.busy, false);
        expect(events, isEmpty);
        backend.fail = false;
        await vm.save('Fixture', '2000-01-01', 'mentor', 'draft');
        expect(vm.profile?.role, 'mentor');
        expect(vm.error, false);
        expect(events, [first]);
      },
    );
    test('duplicate saves ignored while request is pending', () async {
      final result = Completer<Map<String, dynamic>>();
      backend.pending = result;
      final firstSave = vm.save('Fixture', '2000-01-01', 'mentor', 'draft');
      await settleRequests();
      await vm.save('Wrong', '2000-01-01', 'student', '');
      expect(backend.writes, 1);
      expect(vm.profile?.role, 'student');
      result.complete(profile('mentor'));
      await firstSave;
      expect(vm.profile?.role, 'mentor');
      expect(events, [first]);
    });
    test(
      'account change ignores old save and does not notify the new account',
      () async {
        final result = Completer<Map<String, dynamic>>();
        backend.pending = result;
        final save = vm.save('Fixture', '2000-01-01', 'mentor', '');
        await settleRequests();
        await backend.accounts.signIn('second@example.test', 'Fixture1!');
        await settleRequests();
        expect(vm.profile, isNull);
        result.complete(profile('mentor'));
        await save;
        expect(vm.profile, isNull);
        expect(vm.message, isNull);
        expect(vm.busy, false);
        expect(events, isEmpty);
      },
    );
    test(
      'logout and sign-in to the same account rejects old save completion',
      () async {
        final result = Completer<Map<String, dynamic>>();
        backend.pending = result;
        final save = vm.save('Fixture', '2000-01-01', 'mentor', '');
        await settleRequests();
        await backend.accounts.signOut();
        await settleRequests();
        await backend.start();
        await settleRequests();
        result.complete(profile('mentor'));
        await save;
        expect(vm.profile, isNull);
        expect(events, isEmpty);
      },
    );
  });

  test(
    'confirmed same-user changes refresh retained viewmodels and only Home profile data',
    () async {
      final accounts = RoleAccounts();
      final repo = RoleContent(accounts),
          tutors = RoleTutors(accounts),
          dashboard = RoleDashboard(accounts);
      final home = DashboardViewModel(
        accounts.loadProfile,
        repository: dashboard,
        profiles: accounts,
      );
      final explore = ExploreMentorsViewModel(tutors, profiles: accounts);
      final library = ContentLibraryViewModel(repo, profiles: accounts);
      addTearDown(() async {
        home.dispose();
        explore.dispose();
        library.dispose();
        await accounts.close();
        await tutors.changes.close();
      });
      await Future.wait([home.load(), explore.load(), library.load()]);
      explore.search('retained search');
      library.search = 'retained filter';
      for (final role in ['mentor', 'student']) {
        accounts.confirmed(role);
        expect(library.resources, isEmpty);
        expect(explore.ownProfile, isNull);
        await settleRequests();
        expect(home.role, role);
        expect(explore.role, role);
        expect(library.mentor, role == 'mentor');
        expect(library.publisher, role == 'mentor');
        expect(explore.query, 'retained search');
        expect(library.search, 'retained filter');
        expect(
          role == 'mentor'
              ? explore.mentors.isEmpty
              : explore.ownProfile == null,
          true,
        );
      }
      expect(dashboard.projectReads, 1);
      expect(dashboard.sessionReads, 1);
    },
  );

  test(
    'role invalidation rejects old Home, directory and Library responses',
    () async {
      final accounts = RoleAccounts();
      final repo = RoleContent(accounts), tutorRepo = RoleTutors(accounts);
      final oldProfile = Completer<Map<String, dynamic>>();
      var firstRead = true;
      final home = DashboardViewModel(() {
        if (firstRead) {
          firstRead = false;
          return oldProfile.future;
        }
        return accounts.loadProfile();
      }, profiles: accounts);
      final explore = ExploreMentorsViewModel(tutorRepo, profiles: accounts);
      final library = ContentLibraryViewModel(repo, profiles: accounts);
      addTearDown(() async {
        home.dispose();
        explore.dispose();
        library.dispose();
        await accounts.close();
        await tutorRepo.changes.close();
      });
      final directory = Completer<List<Mentor>>();
      tutorRepo.pendingDirectory = directory;
      final resources = Completer<List<LearningResource>>();
      repo.pending = resources;
      final old = Future.wait([home.load(), explore.load(), library.load()]);
      await settleRequests();
      repo.pending = null;
      tutorRepo.pendingDirectory = null;
      accounts.confirmed('mentor');
      await settleRequests();
      oldProfile.complete(profile('student'));
      directory.complete([mentor()]);
      resources.complete([sample]);
      await old;
      expect(home.role, 'mentor');
      expect(explore.role, 'mentor');
      expect(explore.mentors, isEmpty);
      expect(library.mentor, true);
      expect(library.resources, isEmpty);
      expect(library.loading, false);
    },
  );

  testWidgets(
    'role selection is draft, failure retains form, save updates retained tabs both ways',
    (tester) async {
      final accounts = RoleAccounts(),
          notifications = FakeNotificationRepository();
      final tutors = RoleTutors(accounts), content = RoleContent(accounts);
      final badge = NotificationBadgeController(notifications);
      addTearDown(() async {
        badge.dispose();
        await accounts.close();
        await tutors.changes.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: MainModuleShell(
            projectRepository: FakeProjectRepository(),
            kanbanRepository: FakeKanbanRepository(),
            notificationRepository: notifications,
            badgeController: badge,
            marketplace: MarketplaceDependencies.inject(
              accounts: accounts,
              tutors: tutors,
              content: content,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tab(tester, 'Explore');
      expect(find.text('Find your next mentor.'), findsOneWidget);
      await tab(tester, 'Library');
      expect(find.text('Add resource'), findsNothing);
      await tab(tester, 'Profile');
      Future<void> choose(String label) async {
        final field = find.byType(DropdownButtonFormField<String>);
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await choose('Mentor');
      expect(accounts.saves, 0);
      expect(accounts.row['role'], 'student');
      await tab(tester, 'Explore');
      expect(find.text('Find your next mentor.'), findsOneWidget);
      await tab(tester, 'Library');
      expect(find.text('Add resource'), findsNothing);
      await tab(tester, 'Profile');
      Future<void> save() async {
        final button = find.text('Save profile');
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
      }

      accounts.fail = true;
      await save();
      expect(accounts.row['role'], 'student');
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .initialValue,
        'mentor',
      );
      expect(
        find.textContaining('Could not complete the request'),
        findsOneWidget,
      );
      accounts.fail = false;
      await save();
      expect(accounts.row['role'], 'mentor');
      await tab(tester, 'Library');
      expect(find.text('Add resource'), findsOneWidget);
      await tab(tester, 'Explore');
      expect(find.text('Share your teaching profile.'), findsOneWidget);
      await tab(tester, 'Profile');
      await choose('Student');
      await save();
      await tab(tester, 'Library');
      expect(find.text('Add resource'), findsNothing);
      await tab(tester, 'Explore');
      expect(find.text('Find your next mentor.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
