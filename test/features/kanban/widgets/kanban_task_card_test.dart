import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/utils/task_tag_color_utils.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/kanban_task_card.dart';
import 'package:skilltrack/features/kanban/widgets/task_tag_chip.dart';
import 'package:skilltrack/features/kanban/widgets/task_details_sheet.dart';

import '../fake_repository.dart';

void main() {
  testWidgets('task card shows essential details and actions', (tester) async {
    final task = sampleTask('1', 'Build prototype', KanbanStatus.todo);
    TaskCardAction? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KanbanTaskCard(
            task: task,
            onTap: () {},
            onAction: (action) => selected = action,
          ),
        ),
      ),
    );
    expect(find.text('Build prototype'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);
    await tester.tap(find.byTooltip('Task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View details'));
    expect(selected, TaskCardAction.details);
  });

  testWidgets('task card uses tag colors and caps crowded tag lists', (
    tester,
  ) async {
    final tags = [
      for (var i = 0; i < 4; i++)
        TaskTag(
          id: 'tag-$i',
          ownerId: 'user-1',
          name: 'Tag $i',
          colorHex: i == 0 ? '#E53935' : '#00897B',
        ),
    ];
    final task = sampleTask(
      '1',
      'Build prototype',
      KanbanStatus.todo,
      tags: tags,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KanbanTaskCard(task: task, onTap: () {}, onAction: (_) {}),
        ),
      ),
    );
    expect(find.byType(TaskTagChip), findsNWidgets(3));
    expect(find.text('+1'), findsOneWidget);
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip).first).tag.colorHex,
      '#E53935',
    );
    expect(
      TaskTagColorUtils.base(tags.first.colorHex),
      const Color(0xFFE53935),
    );
  });

  testWidgets('task details show every assigned colored tag', (tester) async {
    final tags = [
      for (var i = 0; i < 4; i++)
        TaskTag(
          id: 'tag-$i',
          ownerId: 'user-1',
          name: 'Tag $i',
          colorHex: '#8E24AA',
        ),
    ];
    final repository = FakeKanbanRepository(
      tasks: [sampleTask('1', 'Study', KanbanStatus.todo, tags: tags)],
    )..tags = tags;
    final model = KanbanViewModel(repository);
    await model.initialize();
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailsSheet(taskId: '1', viewModel: model, onEdit: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TaskTagChip), findsNWidgets(4));
    expect(find.text('Tag 3'), findsOneWidget);
  });
}
