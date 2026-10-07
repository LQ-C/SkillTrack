import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/utils/task_tag_color_utils.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/task_tag_chip.dart';
import 'package:skilltrack/features/kanban/widgets/task_tag_color_picker.dart';
import 'package:skilltrack/features/kanban/widgets/tag_management_sheet.dart';

import '../fake_repository.dart';

void main() {
  Future<KanbanViewModel> showEditor(
    WidgetTester tester,
    FakeKanbanRepository repository, {
    TaskTag? tag,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = KanbanViewModel(repository);
    await model.initialize();
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTaskTagEditor(context, model, tag: tag),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    return model;
  }

  testWidgets('all 16 colors render and the default is selected', (
    tester,
  ) async {
    await showEditor(tester, FakeKanbanRepository());
    for (final hex in predefinedTagColors) {
      expect(find.byKey(Key('tag-color-$hex')), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('tag-color-#5C6BC0')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip)).tag.colorHex,
      '#5C6BC0',
    );
    await tester.ensureVisible(find.byKey(const Key('tag-color-#E53935')));
    await tester.tap(find.byKey(const Key('tag-color-#E53935')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip)).tag.colorHex,
      '#E53935',
    );
  });

  testWidgets('custom picker validates, cancels and applies hex values', (
    tester,
  ) async {
    await showEditor(tester, FakeKanbanRepository());
    await tester.ensureVisible(find.byKey(const Key('custom-color-button')));
    await tester.tap(find.byKey(const Key('custom-color-button')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('custom-hex-field')))
          .controller!
          .text,
      '#5C6BC0',
    );
    await tester.enterText(find.byKey(const Key('custom-hex-field')), '#FFF');
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid 6-digit hex color.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('apply-custom-color')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip)).tag.colorHex,
      '#5C6BC0',
    );
    await tester.tap(find.byKey(const Key('custom-color-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('custom-hex-field')), '00ff00');
    await tester.pumpAndSettle();
    expect(
      (tester
                  .widget<Container>(
                    find.byKey(const Key('custom-color-preview')),
                  )
                  .decoration
              as BoxDecoration)
          .color,
      const Color(0xFF00FF00),
    );
    await tester.tap(find.byKey(const Key('apply-custom-color')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip)).tag.colorHex,
      '#00FF00',
    );
  });

  testWidgets('custom hex matching a palette color selects its swatch', (
    tester,
  ) async {
    await showEditor(tester, FakeKanbanRepository());
    await tester.tap(find.byKey(const Key('custom-color-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('custom-hex-field')),
      '#e53935',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply-custom-color')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip)).tag.colorHex,
      '#E53935',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('tag-color-#E53935')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('editing a custom color initializes the picker', (tester) async {
    const tag = TaskTag(
      id: 'tag-1',
      ownerId: 'user-1',
      name: 'Custom',
      colorHex: '#123ABC',
    );
    final repository = FakeKanbanRepository()..tags = [tag];
    await showEditor(tester, repository, tag: tag);
    expect(find.text('Custom Color · #123ABC'), findsOneWidget);
    await tester.tap(find.byKey(const Key('custom-color-button')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('custom-hex-field')))
          .controller!
          .text,
      '#123ABC',
    );
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip)).tag.colorHex,
      '#123ABC',
    );
  });

  testWidgets('create saves selected color and edit preselects stored color', (
    tester,
  ) async {
    final repository = FakeKanbanRepository();
    final model = await showEditor(tester, repository);
    await tester.enterText(find.byKey(const Key('tag-name-field')), 'Revision');
    await tester.ensureVisible(find.byKey(const Key('tag-color-#8E24AA')));
    await tester.tap(find.byKey(const Key('tag-color-#8E24AA')));
    await tester.tap(find.byKey(const Key('save-tag-button')));
    await tester.pumpAndSettle();
    expect(model.availableTags.single.colorHex, '#8E24AA');
    expect(repository.tags.single.name, 'Revision');
    await tester.pumpWidget(const SizedBox.shrink());
    await showEditor(tester, repository, tag: repository.tags.single);
    expect(
      find.descendant(
        of: find.byKey(const Key('tag-color-#8E24AA')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('save failure keeps the tag form and selected color', (
    tester,
  ) async {
    final repository = FakeKanbanRepository()..failTagCreate = true;
    await showEditor(tester, repository);
    await tester.enterText(find.byKey(const Key('tag-name-field')), 'Coding');
    await tester.tap(find.byKey(const Key('tag-color-#1E88E5')));
    await tester.tap(find.byKey(const Key('save-tag-button')));
    await tester.pumpAndSettle();
    expect(
      find.text('Unable to save the tag. Please try again.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tag-name-field')))
          .controller!
          .text,
      'Coding',
    );
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip)).tag.colorHex,
      '#1E88E5',
    );
    repository.failTagCreate = false;
    await tester.tap(find.byKey(const Key('save-tag-button')));
    await tester.pumpAndSettle();
    expect(repository.tags.single.colorHex, '#1E88E5');
  });

  testWidgets('HSV controls keep the hex field synchronized', (tester) async {
    await showEditor(tester, FakeKanbanRepository());
    await tester.tap(find.byKey(const Key('custom-color-button')));
    await tester.pumpAndSettle();
    final initial = tester
        .widget<TextField>(find.byKey(const Key('custom-hex-field')))
        .controller!
        .text;
    final hue = tester.getRect(find.byKey(const Key('tag-hue-slider')));
    await tester.tapAt(Offset(hue.right - 24, hue.center.dy));
    await tester.pumpAndSettle();
    final afterHue = tester
        .widget<TextField>(find.byKey(const Key('custom-hex-field')))
        .controller!
        .text;
    expect(afterHue, isNot(initial));
    final square = tester.getRect(
      find.byKey(const Key('saturation-value-picker')),
    );
    await tester.tapAt(Offset(square.left + 15, square.top + 15));
    await tester.pumpAndSettle();
    final afterSquare = tester
        .widget<TextField>(find.byKey(const Key('custom-hex-field')))
        .controller!
        .text;
    expect(afterSquare, isNot(afterHue));
    expect(TaskTag.isValidHex(afterSquare), true);
  });

  testWidgets('white and black chips keep readable text and visible borders', (
    tester,
  ) async {
    const white = TaskTag(
      id: 'white',
      ownerId: 'user-1',
      name: 'White',
      colorHex: '#FFFFFF',
    );
    const black = TaskTag(
      id: 'black',
      ownerId: 'user-1',
      name: 'Black',
      colorHex: '#000000',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Wrap(
            children: [
              TaskTagChip(tag: white),
              TaskTagChip(tag: black, selected: true),
            ],
          ),
        ),
      ),
    );
    expect(find.text('White'), findsOneWidget);
    expect(find.text('Black'), findsOneWidget);
    expect(TaskTagColorUtils.border('#FFFFFF'), isNot(const Color(0xFFFFFFFF)));
    expect(
      TaskTagColorUtils.foreground('#000000'),
      isNot(TaskTagColorUtils.background('#000000')),
    );
  });

  testWidgets('manage tags edits colors and delete leaves tasks intact', (
    tester,
  ) async {
    const tag = TaskTag(
      id: 'tag-1',
      ownerId: 'user-1',
      name: 'Research',
      colorHex: '#00897B',
    );
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('1', 'Plan', KanbanStatus.todo, tags: [tag]),
      ],
    )..tags = [tag];
    final model = KanbanViewModel(repository);
    await model.initialize();
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: TagManagementSheet(viewModel: model)),
      ),
    );
    await tester.tap(find.byTooltip('Edit Research'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('tag-color-#00897B')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete Research'));
    await tester.pumpAndSettle();
    expect(find.text('Delete tag?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(repository.stored.single.id, '1');
    expect(model.availableTags, isEmpty);
    expect(model.tasks(KanbanStatus.todo).single.tags, isEmpty);
  });
}
