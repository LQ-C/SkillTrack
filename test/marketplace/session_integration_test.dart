import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/app/views/account_gate.dart';
import 'package:skilltrack/app/marketplace_dependencies.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/features/authentication/views/auth_screen.dart';
import 'package:skilltrack/features/projects/repositories/supabase_project_repository.dart';
import 'package:skilltrack/features/kanban/repositories/supabase_kanban_repository.dart';
import 'package:skilltrack/features/learning_integration/repositories/supabase_recommendation_repository.dart';
import 'package:skilltrack/features/educational_content/repositories/supabase_content_repository.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';

const first = '00000000-0000-4000-8000-000000000001';
const second = '00000000-0000-4000-8000-000000000002';

class MemoryPkce extends GotrueAsyncStorage {
  final values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => values[key];
  @override
  Future<void> setItem({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    values.remove(key);
  }
}

String token(String id) {
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'sub': id, 'exp': 4102444800})))
      .replaceAll('=', '');
  return 'eyJhbGciOiJIUzI1NiJ9.$payload.fixture';
}

Map<String, dynamic> user(String id) => {
  'id': id,
  'aud': 'authenticated',
  'role': 'authenticated',
  'email': 'fixture@example.test',
  'email_confirmed_at': '2026-01-01T00:00:00Z',
  'created_at': '2026-01-01T00:00:00Z',
  'app_metadata': {},
  'user_metadata': {},
};
SupabaseClient fixture(List<http.Request> requests) => SupabaseClient(
  'https://fixture.supabase.co',
  'fixture-public-key',
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
    if (request.url.path.endsWith('/signup')) {
      return http.Response(jsonEncode({'user': user(first)}), 200);
    }
    if (request.url.path.contains('/storage/v1/object/sign/')) {
      return http.Response(
        jsonEncode({'signedURL': '/object/sign/private-fixture?token=fixture'}),
        200,
      );
    }
    return http.Response('{}', 200);
  }),
);

class Counter extends StatefulWidget {
  const Counter({super.key});
  @override
  State<Counter> createState() => _CounterState();
}

class _CounterState extends State<Counter> {
  int count = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => setState(() => count++),
      child: Text('Private state $count'),
    ),
  );
}

void main() {
  test(
    'one real client session controls project task and recommendation ownership',
    () async {
      final requests = <http.Request>[], client = fixture(requests);
      addTearDown(client.dispose);
      final account = AccountService(client),
          projects = SupabaseProjectRepository(client),
          tasks = SupabaseKanbanRepository(client),
          resources = SupabaseRecommendationRepository(client);
      await account.signIn('first@example.test', 'Fixture1!');
      expect(projects.currentUserId, first);
      expect(tasks.currentUserId, first);
      expect(resources.currentUserId, first);
      await account.signIn('second@example.test', 'Fixture1!');
      expect(projects.currentUserId, second);
      expect(tasks.currentUserId, second);
      expect(resources.currentUserId, second);
      await account.sendPasswordReset('second@example.test');
      expect(requests.last.url.path, endsWith('/recover'));
      expect(
        requests.last.url.queryParameters['redirect_to'],
        'com.skilltrack.app://login-callback/',
      );
      await account.signOut();
      expect(projects.currentUserId, isNull);
      expect(tasks.currentUserId, isNull);
      expect(resources.currentUserId, isNull);
    },
  );
  testWidgets(
    'account switching discards private tab state and logout shows authentication',
    (tester) async {
      late SupabaseClient client;
      await tester.runAsync(() async {
        client = fixture([]);
      });
      addTearDown(() => tester.runAsync(client.dispose));
      final dependencies = MarketplaceDependencies(client);
      await tester.pumpWidget(
        MaterialApp(
          home: AccountGate(dependencies: dependencies, child: const Counter()),
        ),
      );
      expect(find.byType(AuthScreen), findsOneWidget);
      await tester.runAsync(
        () => client.auth.signInWithPassword(
          email: 'first@example.test',
          password: 'Fixture1!',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private state 0'));
      await tester.pump();
      expect(find.text('Private state 1'), findsOneWidget);
      await tester.runAsync(
        () => client.auth.signInWithPassword(
          email: 'second@example.test',
          password: 'Fixture1!',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private state 0'), findsOneWidget);
      await tester.runAsync(() => client.auth.signOut());
      await tester.pumpAndSettle();
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byType(Counter), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  test(
    'legacy private files are signed in their verified bucket and foreign URLs fail closed',
    () async {
      final requests = <http.Request>[], client = fixture(requests);
      addTearDown(client.dispose);
      final repo = SupabaseContentRepository(client);
      LearningResource resource(String url) => LearningResource(
        id: first,
        authorId: first,
        authorName: 'Fixture',
        title: 'Private video',
        summary: 'Fixture',
        category: 'Programming',
        level: 'Beginner',
        kind: 'Video',
        body: '',
        link: url,
        tags: [],
        status: 'published',
      );
      final signed = await repo.primaryFileUrl(
        resource(
          'https://fixture.supabase.co/storage/v1/object/authenticated/marketplace-videos/owner/video.mp4',
        ),
      );
      expect(signed, contains('/object/sign/'));
      expect(
        requests.last.url.path,
        contains('/sign/marketplace-videos/owner/video.mp4'),
      );
      final before = requests.length;
      await expectLater(
        repo.primaryFileUrl(
          resource(
            'https://other.invalid/storage/v1/object/authenticated/marketplace-videos/owner/video.mp4',
          ),
        ),
        throwsFormatException,
      );
      expect(requests.length, before);
    },
  );
}
