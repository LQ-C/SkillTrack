import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/dashboard/repositories/dashboard_repository.dart';
import 'package:skilltrack/features/dashboard/viewmodels/dashboard_view_model.dart';
import 'package:skilltrack/features/projects/models/project_with_progress.dart';
import 'package:skilltrack/features/projects/models/learning_project.dart';
import 'package:skilltrack/features/tutor_management/models/tutor_models.dart';

class FakeDashboard implements DashboardRepository {
  @override
  String? userId = 'first';
  final changes = StreamController<String?>.broadcast(sync: true);
  @override
  Stream<String?> get userChanges => changes.stream;
  int calls = 0;
  bool failSession = false;
  bool failProjects = false;
  Completer<DashboardProjects>? pending;
  @override
  Future<DashboardProjects> projects(DateTime now) async {
    calls++;
    if (failProjects) throw StateError("offline");
    if (pending != null) return pending!.future;
    return DashboardProjects(2, 3, 1, []);
  }

  @override
  Future<MentorshipSession?> session(DateTime now) async {
    if (failSession) throw StateError('offline');
    return null;
  }
}

ProjectWithProgress project() => ProjectWithProgress(
  project: LearningProject(
    id: 'p',
    ownerId: 'first',
    name: 'Project',
    status: 'active',
    endDate: DateTime(2026, 12, 1),
  ),
  boardId: 'b',
  totalTaskCount: 4,
  completedTaskCount: 1,
  stalledTaskCount: 1,
);
void main() {
  late FakeDashboard repository;
  late DashboardViewModel vm;
  setUp(() {
    repository = FakeDashboard();
    vm = DashboardViewModel(
      () async => {'full_name': 'Alex', 'role': 'student'},
      repository: repository,
    );
  });
  tearDown(() async {
    vm.dispose();
    await repository.changes.close();
  });
  test(
    'keeps independent counts when sessions fail and targeted retry recovers',
    () async {
      repository.failSession = true;
      await vm.load();
      expect(vm.projects!.active, 2);
      expect(vm.projects!.today, 3);
      expect(vm.projects!.stalled, 1);
      expect(vm.errors, {'session'});
      expect(vm.name, 'Alex');
      repository.failSession = false;
      await vm.retry('session');
      expect(vm.session, isNull);
      expect(vm.errors, isEmpty);
      expect(repository.calls, 1);
    },
  );
  test('deduplicates concurrent refresh and retains displayed data', () async {
    await vm.load();
    repository.pending = Completer();
    final a = vm.load();
    final b = vm.load();
    await Future<void>.delayed(Duration.zero);
    expect(repository.calls, 2);
    expect(vm.projects!.active, 2);
    repository.pending!.complete(DashboardProjects(0, 0, 0, []));
    await Future.wait([a, b]);
    expect(vm.projects!.active, 0);
    expect(vm.projects!.items, isEmpty);
  });
  test('old account response cannot replace the new account state', () async {
    final old = Completer<DashboardProjects>();
    repository.pending = old;
    final first = vm.load();
    await Future<void>.delayed(Duration.zero);
    repository.pending = null;
    repository.userId = 'second';
    repository.changes.add('second');
    await vm.load();
    old.complete(DashboardProjects(99, 99, 99, []));
    await first;
    expect(vm.projects!.active, 2);
    repository.userId = null;
    repository.changes.add(null);
    expect(vm.projects, isNull);
    expect(vm.session, isNull);
  });
  test(
    'project failure is distinct from empty and retains previous data',
    () async {
      repository.failProjects = true;
      await vm.load();
      expect(vm.projects, isNull);
      expect(vm.errors, contains('projects'));
      repository.failProjects = false;
      await vm.retry('projects');
      expect(vm.projects!.active, 2);
      repository.failProjects = true;
      await vm.load();
      expect(vm.projects!.active, 2);
      expect(vm.errors, contains('projects'));
    },
  );
  test('shared project progress handles empty and populated projects', () {
    expect(project().progress, 0.25);
    expect(
      project().copyWith(totalTaskCount: 0, completedTaskCount: 0).progress,
      0,
    );
    expect(project().stalledTaskCount, 1);
  });
}
