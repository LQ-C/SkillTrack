import 'dart:collection';

import 'kanban_status.dart';
import 'task_attachment.dart';
import 'task_checklist_item.dart';
import 'task_priority.dart';
import 'task_tag.dart';

class KanbanTask {
  KanbanTask({
    required this.id,
    required this.boardId,
    required this.title,
    this.description = '',
    required this.status,
    required this.priority,
    this.deadline,
    required this.sortOrder,
    this.completedAt,
    this.isArchived = false,
    required this.createdAt,
    required this.updatedAt,
    List<TaskTag> tags = const [],
    List<TaskChecklistItem> checklistItems = const [],
    List<TaskAttachment> attachments = const [],
  }) : tags = UnmodifiableListView(tags),
       checklistItems = UnmodifiableListView(checklistItems),
       attachments = UnmodifiableListView(attachments);

  final String id, boardId, title, description;
  final KanbanStatus status;
  final TaskPriority priority;
  final DateTime? deadline, completedAt;
  final int sortOrder;
  final bool isArchived;
  final DateTime createdAt, updatedAt;
  final List<TaskTag> tags;
  final List<TaskChecklistItem> checklistItems;
  final List<TaskAttachment> attachments;

  bool get isCompleted => status == KanbanStatus.completed;
  bool get isOverdue {
    if (isCompleted || deadline == null) return false;
    final today = DateTime.now();
    return _day(deadline!).isBefore(_day(today));
  }

  bool get isDueSoon {
    if (isCompleted || deadline == null || isOverdue) return false;
    final today = _day(DateTime.now());
    return !_day(deadline!).isAfter(today.add(const Duration(days: 3)));
  }

  static DateTime _day(DateTime date) =>
      DateTime(date.year, date.month, date.day);
  int get checklistCompletedCount =>
      checklistItems.where((item) => item.isCompleted).length;
  int get checklistTotalCount => checklistItems.length;
  double get checklistProgress => checklistItems.isEmpty
      ? 0
      : checklistCompletedCount / checklistItems.length;

  factory KanbanTask.fromMap(
    Map<String, dynamic> map, {
    List<TaskTag> tags = const [],
    List<TaskChecklistItem> checklistItems = const [],
    List<TaskAttachment> attachments = const [],
  }) => KanbanTask(
    id: map['id'].toString(),
    boardId: map['board_id']?.toString() ?? '',
    title: map['title']?.toString() ?? '',
    description: map['description']?.toString() ?? '',
    status: KanbanStatus.fromValue(map['status']?.toString()),
    priority: TaskPriority.fromValue(map['priority']?.toString()),
    deadline: DateTime.tryParse(map['deadline']?.toString() ?? ''),
    sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
    completedAt: DateTime.tryParse(map['completed_at']?.toString() ?? ''),
    isArchived: map['is_archived'] == true,
    createdAt:
        DateTime.tryParse(map['created_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt:
        DateTime.tryParse(map['updated_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    tags: tags,
    checklistItems: checklistItems,
    attachments: attachments,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'board_id': boardId,
    'title': title,
    'description': description,
    'status': status.value,
    'priority': priority.name,
    'deadline': deadline?.toIso8601String(),
    'sort_order': sortOrder,
    'completed_at': completedAt?.toIso8601String(),
    'is_archived': isArchived,
  };

  KanbanTask copyWith({
    String? id,
    String? boardId,
    String? title,
    String? description,
    KanbanStatus? status,
    TaskPriority? priority,
    DateTime? deadline,
    bool clearDeadline = false,
    int? sortOrder,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    bool? isArchived,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<TaskTag>? tags,
    List<TaskChecklistItem>? checklistItems,
    List<TaskAttachment>? attachments,
  }) => KanbanTask(
    id: id ?? this.id,
    boardId: boardId ?? this.boardId,
    title: title ?? this.title,
    description: description ?? this.description,
    status: status ?? this.status,
    priority: priority ?? this.priority,
    deadline: clearDeadline ? null : deadline ?? this.deadline,
    sortOrder: sortOrder ?? this.sortOrder,
    completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
    isArchived: isArchived ?? this.isArchived,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    tags: tags ?? this.tags,
    checklistItems: checklistItems ?? this.checklistItems,
    attachments: attachments ?? this.attachments,
  );

  @override
  bool operator ==(Object other) =>
      other is KanbanTask &&
      id == other.id &&
      boardId == other.boardId &&
      title == other.title &&
      description == other.description &&
      status == other.status &&
      priority == other.priority &&
      deadline == other.deadline &&
      sortOrder == other.sortOrder &&
      completedAt == other.completedAt &&
      isArchived == other.isArchived &&
      createdAt == other.createdAt &&
      updatedAt == other.updatedAt &&
      _sameList(tags, other.tags) &&
      _sameList(checklistItems, other.checklistItems) &&
      _sameList(attachments, other.attachments);
  @override
  int get hashCode => Object.hash(
    id,
    boardId,
    title,
    description,
    status,
    priority,
    deadline,
    sortOrder,
    completedAt,
    isArchived,
    createdAt,
    updatedAt,
    Object.hashAll(tags),
    Object.hashAll(checklistItems),
    Object.hashAll(attachments),
  );

  static bool _sameList<T>(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
