import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/ai_task_generation/views/generated_task_preview_screen.dart';
import 'package:skilltrack/features/ai_task_generation/view_models/append_task_generation_view_model.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import '../projects/fake_project_repository.dart';
import 'append_task_generation_test.dart' show ReplacementTasks;

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  Future<(FakeProjectRepository, String)> project({DateTime? endDate}) async {
    final projects = FakeProjectRepository();
    final created = await projects.createProject(
      name: 'Learning app',
      description: 'Build a learning app',
      startDate: today.subtract(const Duration(days: 10)),
      endDate: endDate ?? today.add(const Duration(days: 10)),
    );
    return (projects, created.boardId!);
  }

  GeneratedTaskDraft draft(String title, int position) => GeneratedTaskDraft(
    title: title,
    description: 'Implementation task',
    priority: 'medium',
    deadline: today.add(const Duration(days: 2)),
    position: position,
    checklist: ['Plan', 'Implement'],
  );

  testWidgets(
    'replacement preview explains archive behavior and confirmation can be cancelled',
    (tester) async {
      final (projects, board) = await project();
      final tasks = ReplacementTasks();
      final generator = FakeTaskGenerationRepository()
        ..result = [draft('One', 0), draft('Two', 1), draft('Three', 2)];
      final model = AppendTaskGenerationViewModel(
        projectId: projects.stored.single.project.id,
        boardId: board,
        projectRepository: projects,
        taskRepository: tasks,
        generationRepository: generator,
      );
      addTearDown(model.dispose);
      await model.generateMoreTasks(replacementFeedback: 'Smaller steps');
      await tester.pumpWidget(
        MaterialApp(home: GeneratedTaskPreviewScreen(viewModel: model)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Review Replacement Tasks'), findsOneWidget);
      await tester.ensureVisible(find.text('Confirm Replacement'));
      await tester.tap(find.text('Confirm Replacement'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Archive all 2 active tasks'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();
      expect(tasks.writes, isEmpty);
      expect(model.pendingGeneratedTasks.length, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
