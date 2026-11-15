import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/tutor_management/models/tutor_models.dart';
import 'package:skilltrack/features/tutor_management/repositories/tutor_repository.dart';
import 'package:skilltrack/features/tutor_management/views/explore_mentors_screen.dart';
import 'package:skilltrack/features/tutor_management/viewmodels/explore_mentors_view_model.dart';
import 'tutor_management_test.dart' show MemoryTutors, mentor, tutorProfile;

class LoadingTutors extends MemoryTutors implements TutorSessionSource {
  final changes = StreamController<String?>.broadcast(sync: true);
  @override
  Stream<String?> get userChanges => changes.stream;
  Completer<String>? pendingRole;
  Completer<List<Mentor>>? pendingDirectory;
  bool failDirectory = false, failRole = false;
  int roleReads = 0, profileReads = 0, enables = 0;
  @override
  Future<String> role() async {
    roleReads++;
    if (failRole) throw StateError('offline');
    return pendingRole == null ? accountRole : pendingRole!.future;
  }

  @override
  Future<List<Mentor>> directory() async {
    directoryReads++;
    if (failDirectory) throw StateError('offline');
    return pendingDirectory == null ? [mentor()] : pendingDirectory!.future;
  }

  @override
  Future<TutorProfile?> profile() async {
    profileReads++;
    return own;
  }

  @override
  Future<void> enable() async {
    enables++;
    own = tutorProfile('approved');
  }
}

void main() {
  late LoadingTutors repo;
  late ExploreMentorsViewModel vm;
  setUp(() {
    repo = LoadingTutors()
      ..userId = 'student'
      ..accountRole = 'student';
    vm = ExploreMentorsViewModel(
      repo,
      requestTimeout: const Duration(milliseconds: 50),
    );
  });
  tearDown(() async {
    vm.dispose();
    await repo.changes.close();
  });
  test('initial failure retries without fetching unrelated stages', () async {
    repo.failRole = true;
    await vm.load();
    expect(vm.error, isNotNull);
    expect(vm.loading, false);
    expect(vm.hasLoaded, false);
    expect(repo.directoryReads, 0);
    repo.failRole = false;
    repo.failDirectory = true;
    await vm.load();
    expect(vm.hasLoaded, false);
    expect(vm.mentors, isEmpty);
    expect(vm.error, isNotNull);
    repo.failDirectory = false;
    await vm.load();
    expect(vm.error, isNull);
    expect(vm.hasLoaded, true);
    expect(vm.mentors, hasLength(1));
    expect(repo.profileReads, 0);
  });
  test('role gates directory and duplicate loads share one request', () async {
    repo.pendingRole = Completer();
    final a = vm.load(), b = vm.load();
    expect(vm.loading, true);
    expect(repo.directoryReads, 0);
    repo.pendingRole!.complete('student');
    await Future.wait([a, b]);
    expect(repo.roleReads, 1);
    expect(repo.directoryReads, 1);
    expect(repo.profileReads, 0);
    expect(vm.mentors, hasLength(1));
  });
  test(
    'hanging role times out and old response cannot supersede retry',
    () async {
      final old = Completer<String>();
      repo.pendingRole = old;
      await vm.load();
      expect(vm.loading, false);
      expect(vm.error, contains('timed out'));
      expect(repo.directoryReads, 0);
      repo.pendingRole = null;
      await vm.load();
      expect(vm.hasLoaded, true);
      expect(vm.error, isNull);
      old.complete('mentor');
      await Future<void>.delayed(Duration.zero);
      expect(vm.role, 'student');
      expect(repo.profileReads, 0);
    },
  );
  test(
    'directory timeout and failure retain cards and search; retry revalidates role',
    () async {
      await vm.load();
      vm.search('programming');
      final old = Completer<List<Mentor>>();
      repo.pendingDirectory = old;
      final pending = vm.load();
      await Future<void>.delayed(Duration.zero);
      expect(vm.matches, hasLength(1));
      expect(vm.loading, true);
      await pending;
      expect(vm.error, contains('timed out'));
      expect(vm.matches, hasLength(1));
      repo.pendingDirectory = null;
      repo.failDirectory = true;
      await vm.load();
      expect(vm.loading, false);
      expect(vm.matches, hasLength(1));
      repo.failDirectory = false;
      await vm.load();
      expect(vm.error, isNull);
      expect(vm.query, 'programming');
      expect(repo.roleReads, 4);
      old.complete([]);
      await Future<void>.delayed(Duration.zero);
      expect(vm.mentors, hasLength(1));
    },
  );
  test(
    'mentor and other roles never read directory; authoring revalidates role',
    () async {
      repo.accountRole = 'mentor';
      await vm.load();
      expect(repo.directoryReads, 0);
      expect(repo.profileReads, 1);
      final profile = await vm.prepareProfileEditor();
      expect(profile, isNotNull);
      expect(repo.enables, 1);
      repo.accountRole = 'admin';
      await vm.load();
      expect(vm.role, 'admin');
      expect(vm.ownProfile, isNull);
      expect(vm.mentors, isEmpty);
      expect(repo.directoryReads, 0);
      expect(await vm.prepareProfileEditor(), isNull);
      expect(repo.enables, 1);
    },
  );
  test(
    'logout clears role data immediately and rejects old directory response',
    () async {
      await vm.load();
      final old = Completer<List<Mentor>>();
      repo.pendingDirectory = old;
      final pending = vm.load();
      await Future<void>.delayed(Duration.zero);
      repo.changes.add(null);
      expect(vm.role, isNull);
      expect(vm.mentors, isEmpty);
      expect(vm.ownProfile, isNull);
      expect(vm.loading, false);
      repo.pendingDirectory = null;
      repo.userId = 'new-mentor';
      repo.accountRole = 'mentor';
      repo.changes.add('new-mentor');
      await vm.load();
      expect(vm.role, 'mentor');
      old.complete([mentor()]);
      await pending;
      expect(vm.mentors, isEmpty);
    },
  );
  test(
    'account switch during authoring role check cannot enable another account',
    () async {
      repo.accountRole = 'mentor';
      await vm.load();
      final oldRole = Completer<String>();
      repo.pendingRole = oldRole;
      final preparation = vm.prepareProfileEditor();
      repo.userId = 'new-student';
      repo.accountRole = 'student';
      repo.pendingRole = null;
      repo.changes.add('new-student');
      await vm.load();
      oldRole.complete('mentor');
      expect(await preparation, isNull);
      expect(repo.enables, 0);
      expect(vm.role, 'student');
    },
  );
  testWidgets('retained tab and ordinary rebuilds do not reload directory', (
    tester,
  ) async {
    var selected = 0;
    final explore = ExploreMentorsScreen(repository: repo);
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => setState(() => selected = 1 - selected),
                  child: const Text('Switch tab'),
                ),
                Expanded(
                  child: IndexedStack(
                    index: selected,
                    children: [explore, const Text('Other tab')],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.roleReads, 1);
    expect(repo.directoryReads, 1);
    await tester.tap(find.text('Switch tab'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch tab'));
    await tester.pumpAndSettle();
    expect(repo.roleReads, 1);
    expect(repo.directoryReads, 1);
    expect(find.text('Mentor Name'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'refresh keeps mentor cards and search visible and failure offers Retry',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ExploreMentorsScreen(repository: repo)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'programming');
      await tester.pump();
      repo.pendingDirectory = Completer();
      final refresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      expect(find.text('Mentor Name'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'programming',
      );
      repo.pendingDirectory!.completeError(StateError('offline'));
      await refresh;
      await tester.pumpAndSettle();
      expect(find.text('Mentor Name'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      repo.pendingDirectory = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
