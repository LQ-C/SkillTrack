import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:skilltrack/features/educational_content/utils/content_validation.dart';
import 'package:skilltrack/features/educational_content/views/content_screen.dart';
import 'package:skilltrack/features/educational_content/views/resource_editor.dart';
import 'package:skilltrack/features/educational_content/widgets/report_dialog.dart';

const sample = LearningResource(
  id: 'one',
  authorId: 'mentor',
  authorName: 'Liau',
  title: 'Flutter login guide',
  summary: 'Build your first login form with clear practical steps.',
  category: 'Programming',
  level: 'Beginner',
  kind: 'Reading',
  body: '1. Create a form.\n2. Add validated input fields.',
  link: 'https://example.com/flutter-login',
  tags: ['flutter', 'login'],
  status: 'published',
);

class FakeContentRepository implements ContentRepository {
  bool mentor = false, publisher = false, fail = false, empty = false;
  int reads = 0;
  String searched = '';
  Map<String, dynamic>? saved;
  @override
  String userId = 'student';
  @override
  Future<({bool mentor, bool publisher})> permissions() async =>
      (mentor: mentor, publisher: publisher);
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
    searched = search;
    if (fail) throw Exception('offline');
    return empty ||
            mine ||
            !sample.title.toLowerCase().contains(search.toLowerCase())
        ? []
        : [sample];
  }

  @override
  Future<LearningResource> get(String id) async => sample;
  @override
  Future<Set<String>> bookmarks() async => {};
  @override
  Future<void> bookmark(String id, bool save) async {}
  @override
  Future<void> save(Map<String, dynamic> values, {String? id}) async {
    saved = values;
  }

  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> report(String id, String reason, String details) async {}
}

void main() {
  testWidgets(
    'saving a valid guide persists values and returns to the library',
    (tester) async {
      final repository = FakeContentRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ResourceEditor(
                      repository: repository,
                      resource: sample,
                      canPublish: true,
                    ),
                  ),
                ),
                child: const Text('Edit guide'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit guide'));
      await tester.pumpAndSettle();
      final title = find.byType(TextFormField).first;
      await tester.enterText(title, 'Updated login guide');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final save = find.text('Save resource');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repository.saved?['title'], 'Updated login guide');
      expect(repository.saved?['tags'], ['flutter', 'login']);
      expect(find.text('Edit guide'), findsOneWidget);
      expect(find.text('Save resource'), findsNothing);
    },
  );
  test(
    'resource links reject dangerous schemes, credentials and whitespace',
    () {
      for (final url in [
        'javascript:alert(1)',
        'file:///private',
        'http://example.com',
        'https://user:password@example.com',
        'https://example.com/a b',
        'not a link',
      ]) {
        expect(contentLink(url), isNotNull);
      }
      expect(contentLink('https://example.com/lesson?a=1'), isNull);
      expect(contentLink('', required: false), isNull);
      expect(contentLink(''), isNotNull);
    },
  );
  test('tags normalize and deduplicate for recommendation metadata', () {
    expect(parseTags(' Flutter, login, flutter, , Supabase '), [
      'flutter',
      'login',
      'supabase',
    ]);
  });
  testWidgets('students browse granted content but have no upload controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ContentScreen(repository: FakeContentRepository())),
    );
    await tester.pumpAndSettle();
    expect(find.text(sample.title), findsOneWidget);
    expect(find.text('Add resource'), findsNothing);
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('No resources found.'), findsOneWidget);
  });
  testWidgets(
    'student with no unlocked materials sees only the empty message and can refresh',
    (tester) async {
      final repo = FakeContentRepository()..empty = true;
      await tester.pumpWidget(
        MaterialApp(home: ContentScreen(repository: repo)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('You currently have no learning material available'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Category'), findsNothing);
      expect(
        find.text('Learn something.\nPut it into practice.'),
        findsNothing,
      );
      repo.empty = false;
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(find.text(sample.title), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    },
  );
  testWidgets('failed catalog request offers a working retry', (tester) async {
    final repository = FakeContentRepository()..fail = true;
    await tester.pumpWidget(
      MaterialApp(home: ContentScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    repository.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(repository.reads, 2);
    expect(find.text(sample.title), findsOneWidget);
  });
  testWidgets('catalog failure does not hide a confirmed mentor role', (
    tester,
  ) async {
    final repository = FakeContentRepository()
      ..mentor = true
      ..fail = true;
    await tester.pumpWidget(
      MaterialApp(home: ContentScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Published'), findsNothing);
    expect(find.byType(SegmentedButton<bool>), findsNothing);
    expect(find.text('My resources'), findsOneWidget);
    expect(find.text('Add resource'), findsOneWidget);
    expect(find.textContaining('change your account'), findsNothing);
  });
  testWidgets(
    'unapproved mentors can prepare drafts but cannot select published',
    (tester) async {
      final repository = FakeContentRepository()..mentor = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ResourceEditor(repository: repository, canPublish: false),
        ),
      );
      await tester.pumpAndSettle();
      final visibility = find.byType(DropdownButtonFormField<String>).last;
      await tester.ensureVisible(visibility);
      await tester.pumpAndSettle();
      await tester.tap(visibility);
      await tester.pumpAndSettle();
      expect(find.text('Published — all signed-in learners'), findsNothing);
      expect(find.text('Archived — only you'), findsOneWidget);
    },
  );
  testWidgets('editor rejects empty resource and invalid URL before saving', (
    tester,
  ) async {
    final repository = FakeContentRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: ResourceEditor(repository: repository, canPublish: true),
      ),
    );
    final save = find.text('Save resource');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(repository.saved, isNull);
    await tester.ensureVisible(find.text('Title must be 3–120 characters.'));
    expect(find.text('Title must be 3–120 characters.'), findsOneWidget);
  });
  testWidgets('report requires meaningful details', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ReportDialog())));
    await tester.tap(find.text('Submit report'));
    await tester.pump();
    expect(
      find.text('Report details must be 10–1000 characters.'),
      findsOneWidget,
    );
  });
  testWidgets('library fits a narrow phone with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: ContentScreen(repository: FakeContentRepository()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
