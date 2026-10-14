import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/models/task_attachment.dart';
import 'package:skilltrack/features/kanban/models/task_checklist_item.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';

import '../fake_repository.dart';

void main() {
  final base = sampleTask('task', 'Study', KanbanStatus.inProgress);
  final stalledAt = DateTime.utc(2026, 10, 10, 9);
  final checkedAt = DateTime.utc(2026, 10, 11, 10);
  final stored = {
    ...base.toMap(),
    'stagnation_score': 80,
    'is_stalled': true,
    'stalled_at': stalledAt.toIso8601String(),
    'stagnation_checked_at': checkedAt.toIso8601String(),
    'last_activity_at': '2026-10-11T18:00:00+08:00',
  };

  test(
    'parses stored stagnation fields and normalizes last activity to UTC',
    () {
      final task = KanbanTask.fromMap(stored);
      expect(task.stagnationScore, 80);
      expect(task.isStalled, isTrue);
      expect(task.stalledAt, stalledAt);
      expect(task.stagnationCheckedAt, checkedAt);
      expect(task.lastActivityAt, checkedAt);
      expect(task.lastActivityAt!.isUtc, isTrue);
      expect(task.stagnationLabel, 'Stalled');
      expect(task.isAtRisk, isFalse);
    },
  );

  test('missing or invalid optional values use safe defaults', () {
    for (final map in [
      base.toMap(),
      {
        ...base.toMap(),
        'stalled_at': 'bad',
        'stagnation_checked_at': 'bad',
        'last_activity_at': 'bad',
      },
      {
        ...base.toMap(),
        'stagnation_score': null,
        'is_stalled': null,
        'last_activity_at': null,
      },
    ]) {
      final task = KanbanTask.fromMap(map);
      expect(task.stagnationScore, 0);
      expect(task.isStalled, isFalse);
      expect(task.stalledAt, isNull);
      expect(task.stagnationCheckedAt, isNull);
      expect(task.lastActivityAt, isNull);
      expect(task.stagnationLabel, 'Active');
    }
  });

  test('malformed scores are safe and every model score is bounded', () {
    for (final entry in <Object?, int>{
      null: 0,
      'bad': 0,
      true: 0,
      double.nan: 0,
      double.infinity: 0,
      -20: 0,
      130: 100,
      59.9: 59,
      '55': 55,
    }.entries) {
      expect(
        KanbanTask.fromMap({
          ...base.toMap(),
          'stagnation_score': entry.key,
        }).stagnationScore,
        entry.value,
      );
    }
    expect(base.copyWith(stagnationScore: -1).stagnationScore, 0);
    expect(base.copyWith(stagnationScore: 101).stagnationScore, 100);
    expect(base.copyWith(stagnationScore: 101).stagnationProgress, 1);
    expect(base.copyWith(stagnationScore: -1).stagnationProgress, 0);
  });

  test('copyWith preserves, replaces and clears stagnation values', () {
    final task = KanbanTask.fromMap(stored);
    final edited = task.copyWith(title: 'Edited', sortOrder: 500);
    expect(edited.stagnationScore, 80);
    expect(edited.isStalled, isTrue);
    expect(edited.stalledAt, stalledAt);
    expect(edited.stagnationCheckedAt, checkedAt);
    expect(edited.lastActivityAt, checkedAt);
    final refreshed = edited.copyWith(
      stagnationScore: 20,
      isStalled: false,
      clearStalledAt: true,
      stagnationCheckedAt: checkedAt.add(const Duration(hours: 1)),
      lastActivityAt: checkedAt.add(const Duration(hours: 1)),
    );
    expect(refreshed.stagnationScore, 20);
    expect(refreshed.isStalled, isFalse);
    expect(refreshed.stalledAt, isNull);
    expect(
      refreshed.stagnationCheckedAt,
      checkedAt.add(const Duration(hours: 1)),
    );
    expect(
      refreshed.copyWith(clearStagnationCheckedAt: true).stagnationCheckedAt,
      isNull,
    );
    expect(refreshed.lastActivityAt, checkedAt.add(const Duration(hours: 1)));
    expect(
      refreshed.copyWith(clearLastActivityAt: true).lastActivityAt,
      isNull,
    );
  });

  test('equality and hashing include all stagnation fields', () {
    final task = KanbanTask.fromMap(stored);
    expect(task.copyWith(), task);
    expect(task.copyWith().hashCode, task.hashCode);
    final variants = [
      task.copyWith(stagnationScore: 81),
      task.copyWith(isStalled: false),
      task.copyWith(stalledAt: stalledAt.add(const Duration(minutes: 1))),
      task.copyWith(
        stagnationCheckedAt: checkedAt.add(const Duration(minutes: 1)),
      ),
      task.copyWith(lastActivityAt: checkedAt.add(const Duration(minutes: 1))),
    ];
    for (final variant in variants) {
      expect(variant, isNot(task));
      expect(variant.hashCode, isNot(task.hashCode));
    }
  });

  test('create and edit maps exclude all server-managed stagnation fields', () {
    final task = KanbanTask.fromMap(stored);
    for (final candidate in [task, task.copyWith(title: 'Edited')]) {
      final map = candidate.toMap();
      for (final key in [
        'stagnation_score',
        'is_stalled',
        'stalled_at',
        'stagnation_checked_at',
        'last_activity_at',
      ]) {
        expect(map.containsKey(key), isFalse);
      }
      expect(map['title'], candidate.title);
      expect(map['status'], candidate.status.value);
    }
  });

  test('risk labels use the backend flag and suppress inactive tasks', () {
    expect(base.copyWith(stagnationScore: 49).shouldShowStagnation, isFalse);
    for (final score in [50, 55, 69]) {
      final task = base.copyWith(stagnationScore: score);
      expect(task.isAtRisk, isTrue);
      expect(task.shouldShowStagnation, isTrue);
      expect(task.stagnationLabel, 'At risk');
    }
    for (final score in [70, 75, 100]) {
      final task = base.copyWith(stagnationScore: score);
      expect(task.isAtRisk, isFalse);
      expect(task.shouldShowStalled, isTrue);
      expect(task.stagnationLabel, 'Stalled');
    }
    for (final score in [0, 20, 29]) {
      expect(base.copyWith(stagnationScore: score).stagnationLabel, 'Active');
    }
    for (final score in [30, 40, 49]) {
      expect(base.copyWith(stagnationScore: score).stagnationLabel, 'Low risk');
    }
    final inconsistent = base.copyWith(stagnationScore: 20, isStalled: true);
    expect(inconsistent.stagnationLabel, 'Stalled');
    expect(inconsistent.shouldShowStagnation, isTrue);
    expect(inconsistent.isAtRisk, isFalse);
    final stalled = base.copyWith(stagnationScore: 80, isStalled: true);
    expect(
      stalled.copyWith(status: KanbanStatus.completed).shouldShowStagnation,
      isFalse,
    );
    expect(stalled.copyWith(isArchived: true).shouldShowStagnation, isFalse);
  });

  test('parsing stagnation keeps the fetched task relations', () {
    const tags = [
      TaskTag(id: 'tag', ownerId: 'user', name: 'Study', colorHex: '#00897B'),
    ];
    const checklist = [
      TaskChecklistItem(
        id: 'item',
        taskId: 'task',
        title: 'Read',
        isCompleted: false,
        position: 0,
      ),
    ];
    const attachments = [
      TaskAttachment(
        id: 'file',
        taskId: 'task',
        fileName: 'notes.txt',
        storagePath: 'notes',
      ),
    ];
    final task = KanbanTask.fromMap(
      stored,
      tags: tags,
      checklistItems: checklist,
      attachments: attachments,
    );
    expect(task.tags, tags);
    expect(task.checklistItems, checklist);
    expect(task.attachments, attachments);
    expect(task.copyWith(title: 'Edited').attachments, attachments);
  });
}
