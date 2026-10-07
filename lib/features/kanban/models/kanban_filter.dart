import 'dart:collection';
import 'kanban_status.dart';
import 'task_priority.dart';

class KanbanFilter {
  KanbanFilter({
    Set<KanbanStatus> statuses = const {},
    Set<TaskPriority> priorities = const {},
    Set<String> tagIds = const {},
    this.deadlineStart,
    this.deadlineEnd,
    this.overdueOnly = false,
    this.completedOnly = false,
  }) : statuses = UnmodifiableSetView(statuses),
       priorities = UnmodifiableSetView(priorities),
       tagIds = UnmodifiableSetView(tagIds);
  final Set<KanbanStatus> statuses;
  final Set<TaskPriority> priorities;
  final Set<String> tagIds;
  final DateTime? deadlineStart, deadlineEnd;
  final bool overdueOnly, completedOnly;
  bool get isActive =>
      statuses.isNotEmpty ||
      priorities.isNotEmpty ||
      tagIds.isNotEmpty ||
      deadlineStart != null ||
      deadlineEnd != null ||
      overdueOnly ||
      completedOnly;
  KanbanFilter copyWith({
    Set<KanbanStatus>? statuses,
    Set<TaskPriority>? priorities,
    Set<String>? tagIds,
    DateTime? deadlineStart,
    DateTime? deadlineEnd,
    bool clearDeadlineStart = false,
    bool clearDeadlineEnd = false,
    bool? overdueOnly,
    bool? completedOnly,
  }) => KanbanFilter(
    statuses: statuses ?? this.statuses,
    priorities: priorities ?? this.priorities,
    tagIds: tagIds ?? this.tagIds,
    deadlineStart: clearDeadlineStart
        ? null
        : deadlineStart ?? this.deadlineStart,
    deadlineEnd: clearDeadlineEnd ? null : deadlineEnd ?? this.deadlineEnd,
    overdueOnly: overdueOnly ?? this.overdueOnly,
    completedOnly: completedOnly ?? this.completedOnly,
  );
  KanbanFilter clear() => KanbanFilter();
}
