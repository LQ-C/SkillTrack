import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/projects/viewmodels/create_project_view_model.dart';
import 'package:skilltrack/features/projects/viewmodels/project_dashboard_view_model.dart';

import 'fake_project_repository.dart';

void main() {
  test('dashboard loads only owned projects and calculates summary', () async {
    final repo = FakeProjectRepository(
      items: [
        sampleProject('1', 'Flutter', total: 8, completed: 3),
        sampleProject('2', 'Done', status: 'completed'),
        sampleProject('3', 'Other user', ownerId: 'user-2'),
      ],
    );
    final model = ProjectDashboardViewModel(repo);
    await model.load();
    expect(model.projects.length, 2);
    expect(model.totalCount, 2);
    expect(model.activeCount, 1);
    expect(model.completedCount, 1);
    expect(model.projects.first.progress, 3 / 8);
    expect(model.projects.last.progress, 0);
    model.dispose();
  });

  test('dashboard searches, filters, archives and deletes', () async {
    final repo = FakeProjectRepository(
      items: [sampleProject('1', 'Flutter'), sampleProject('2', 'Python')],
    );
    final model = ProjectDashboardViewModel(repo);
    await model.load();
    model.search('  FLUT  ');
    expect(model.visibleProjects.single.project.name, 'Flutter');
    model.search('');
    expect(await model.archive('1'), true);
    expect(model.visibleProjects.map((item) => item.project.name), ['Python']);
    model.filter('archived');
    expect(model.visibleProjects.single.project.name, 'Flutter');
    expect(await model.delete('1'), true);
    expect(repo.deleteCalled, true);
    expect(model.visibleProjects, isEmpty);
    model.dispose();
  });

  test(
    'creation validates name and dates, then creates project and board',
    () async {
      final repo = FakeProjectRepository();
      final model = CreateProjectViewModel(repo);
      expect(await model.submit(name: '   ', description: ''), null);
      expect(model.nameError, 'Project name is required.');
      expect(
        await model.submit(
          name: 'Flutter',
          description: '',
          startDate: DateTime(2026, 10, 7),
          endDate: DateTime(2026, 10, 6),
        ),
        null,
      );
      expect(
        model.dateError,
        'End date cannot be earlier than the start date.',
      );
      final created = await model.submit(
        name: '  Flutter  ',
        description: '  Study  ',
      );
      expect(created?.project.name, 'Flutter');
      expect(created?.project.description, 'Study');
      expect(created?.project.status, 'active');
      expect(created?.boardId, isNotNull);
      expect(repo.stored.single.project.id, created?.project.id);
      model.dispose();
    },
  );

  test('board creation failure leaves no project in dashboard', () async {
    final repo = FakeProjectRepository()..failBoardCreation = true;
    final model = CreateProjectViewModel(repo);
    expect(await model.submit(name: 'Flutter', description: ''), null);
    expect(
      model.errorMessage,
      'Unable to create the project. Please try again.',
    );
    expect(repo.stored, isEmpty);
    model.dispose();
  });

  test('editing a project updates its fields and status', () async {
    final repo = FakeProjectRepository(items: [sampleProject('1', 'Flutter')]);
    final model = CreateProjectViewModel(
      repo,
      original: repo.stored.single.project,
    );
    final result = await model.submit(
      name: '  Flutter Advanced  ',
      description: '  ',
      status: 'completed',
      startDate: DateTime(2026, 10, 1),
    );
    expect(result?.project.name, 'Flutter Advanced');
    expect(result?.project.description, null);
    expect(repo.stored.single.project.status, 'completed');
    expect(repo.stored.single.project.startDate, DateTime(2026, 10, 1));
    model.dispose();
  });
}
