import 'dart:collection';

import '../../../core/utils/date_formatter.dart';

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
    this.deadlineHasTime,
    required this.sortOrder,
    this.completedAt,
    this.milestoneId,
    this.elapsedSeconds = 0,
    this.trackingStartedAt,
    this.isArchived = false,
    int stagnationScore = 0,
    this.isStalled = false,
    this.stalledAt,
    this.stagnationCheckedAt,
    this.lastActivityAt,
    required this.createdAt,
    required this.updatedAt,
    List<TaskTag> tags = const [],
    List<TaskChecklistItem> checklistItems = const [],
    List<TaskAttachment> attachments = const [],
  }) : stagnationScore = stagnationScore.clamp(0, 100),
       tags = UnmodifiableListView(tags),
       checklistItems = UnmodifiableListView(checklistItems),
       attachments = UnmodifiableListView(attachments);

  final String id, boardId, title, description;
  final String? milestoneId;
  final KanbanStatus status;
  final TaskPriority priority;
  final DateTime? deadline, completedAt;
  // Null means legacy/unknown. Never infer date-only intent from midnight.
  final bool? deadlineHasTime;
  bool get hasDeadlineTime => deadline != null && deadlineHasTime != false;
  final int elapsedSeconds;
  final DateTime? trackingStartedAt;
  final int sortOrder;
  final bool isArchived;
  final int stagnationScore;
  final bool isStalled;
  final DateTime? stalledAt, stagnationCheckedAt;
  final DateTime? lastActivityAt;
  final DateTime createdAt, updatedAt;
  final List<TaskTag> tags;
  final List<TaskChecklistItem> checklistItems;
  final List<TaskAttachment> attachments;

  bool get isTracking =>
      status == KanbanStatus.inProgress &&
      !isArchived &&
      trackingStartedAt != null;

  Duration trackedDurationAt(DateTime now) {
    final saved = elapsedSeconds < 0 ? 0 : elapsedSeconds;
    final session = isTracking
        ? now.toUtc().difference(trackingStartedAt!).inSeconds
        : 0;
    return Duration(seconds: saved + (session < 0 ? 0 : session));
  }

  bool get isCompleted => status == KanbanStatus.completed;
  bool get shouldShowStalled => isStalled || stagnationScore >= 70;
  bool get isAtRisk => !shouldShowStalled && stagnationScore >= 50;
  double get stagnationProgress => stagnationScore / 100.0;
  bool get shouldShowStagnation =>
      !isCompleted &&
      !isArchived &&
      (shouldShowStalled || stagnationScore >= 50);
  String get stagnationLabel => shouldShowStalled
      ? 'Stalled'
      : stagnationScore >= 50
      ? 'At risk'
      : stagnationScore >= 30
      ? 'Low risk'
      : 'Active';
  bool get isOverdue => isOverdueAt(DateTime.now());

  bool isOverdueAt(DateTime now) {
    if (isCompleted || deadline == null) return false;
    return deadline!.isBefore(now.toUtc());
  }

  bool get isDueSoon => isDueSoonAt(DateTime.now());

  bool isDueSoonAt(DateTime now) {
    if (isCompleted || deadline == null || isOverdueAt(now)) return false;
    final today = DateFormatter.today(now: now);
    final day = DateFormatter.dateOnly(DateFormatter.malaysiaTime(deadline!));
    return !day.isAfter(DateTime(today.year, today.month, today.day + 3));
  }

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
    milestoneId: map['milestone_id'] as String?,
    description: map['description']?.toString() ?? '',
    status: KanbanStatus.fromValue(map['status']?.toString()),
    priority: TaskPriority.fromValue(map['priority']?.toString()),
    deadline: DateTime.tryParse(map['deadline']?.toString() ?? '')?.toUtc(),
    deadlineHasTime: map['deadline_has_time'] as bool?,
    sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
    completedAt: DateTime.tryParse(map['completed_at']?.toString() ?? ''),
    elapsedSeconds: _readElapsedSeconds(map['elapsed_seconds']),
    trackingStartedAt: DateTime.tryParse(
      map['tracking_started_at']?.toString() ?? '',
    )?.toUtc(),
    isArchived: map['is_archived'] == true,
    stagnationScore: _readScore(map['stagnation_score']),
    isStalled: map['is_stalled'] == true,
    stalledAt: DateTime.tryParse(map['stalled_at']?.toString() ?? ''),
    stagnationCheckedAt: DateTime.tryParse(
      map['stagnation_checked_at']?.toString() ?? '',
    ),
    lastActivityAt: DateTime.tryParse(
      map['last_activity_at']?.toString() ?? '',
    )?.toUtc(),
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

  // Server-managed stagnation and tracking fields are excluded from writes.
  Map<String, dynamic> toMap() => {
    'id': id,
    'board_id': boardId,
    'title': title,
    'milestone_id': milestoneId,
    'description': description,
    'status': status.value,
    'priority': priority.name,
    'deadline': deadline?.toUtc().toIso8601String(),
    'deadline_has_time': deadline == null ? null : deadlineHasTime,
    'sort_order': sortOrder,
    'completed_at': completedAt?.toUtc().toIso8601String(),
    'is_archived': isArchived,
  };

  KanbanTask copyWith({
    String? id,
    String? boardId,
    String? title,
    String? description,
    String? milestoneId,
    bool clearMilestone = false,
    KanbanStatus? status,
    TaskPriority? priority,
    DateTime? deadline,
    bool? deadlineHasTime,
    bool clearDeadline = false,
    int? sortOrder,
    DateTime? completedAt,
    int? elapsedSeconds,
    DateTime? trackingStartedAt,
    bool clearTrackingStartedAt = false,
    bool clearCompletedAt = false,
    bool? isArchived,
    int? stagnationScore,
    bool? isStalled,
    DateTime? stalledAt,
    bool clearStalledAt = false,
    DateTime? stagnationCheckedAt,
    bool clearStagnationCheckedAt = false,
    DateTime? lastActivityAt,
    bool clearLastActivityAt = false,
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
    milestoneId: clearMilestone ? null : milestoneId ?? this.milestoneId,
    status: status ?? this.status,
    priority: priority ?? this.priority,
    deadline: clearDeadline ? null : deadline ?? this.deadline,
    deadlineHasTime: clearDeadline
        ? null
        : deadlineHasTime ?? this.deadlineHasTime,
    sortOrder: sortOrder ?? this.sortOrder,
    completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
    elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
    trackingStartedAt: clearTrackingStartedAt
        ? null
        : trackingStartedAt ?? this.trackingStartedAt,
    isArchived: isArchived ?? this.isArchived,
    stagnationScore: stagnationScore ?? this.stagnationScore,
    isStalled: isStalled ?? this.isStalled,
    stalledAt: clearStalledAt ? null : stalledAt ?? this.stalledAt,
    stagnationCheckedAt: clearStagnationCheckedAt
        ? null
        : stagnationCheckedAt ?? this.stagnationCheckedAt,
    lastActivityAt: clearLastActivityAt
        ? null
        : lastActivityAt ?? this.lastActivityAt,
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
      milestoneId == other.milestoneId &&
      status == other.status &&
      priority == other.priority &&
      deadline == other.deadline &&
      deadlineHasTime == other.deadlineHasTime &&
      sortOrder == other.sortOrder &&
      completedAt == other.completedAt &&
      elapsedSeconds == other.elapsedSeconds &&
      trackingStartedAt == other.trackingStartedAt &&
      isArchived == other.isArchived &&
      stagnationScore == other.stagnationScore &&
      isStalled == other.isStalled &&
      stalledAt == other.stalledAt &&
      stagnationCheckedAt == other.stagnationCheckedAt &&
      lastActivityAt == other.lastActivityAt &&
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
    stagnationScore,
    isStalled,
    stalledAt,
    stagnationCheckedAt,
    lastActivityAt,
    createdAt,
    updatedAt,
    Object.hash(
      milestoneId,
      deadlineHasTime,
      elapsedSeconds,
      trackingStartedAt,
      Object.hashAll(tags),
      Object.hashAll(checklistItems),
      Object.hashAll(attachments),
    ),
  );

  static int _readElapsedSeconds(dynamic value) {
    final seconds = value is num
        ? value
        : num.tryParse(value?.toString() ?? '');
    return seconds != null && seconds.isFinite && seconds > 0
        ? seconds.toInt()
        : 0;
  }

  static int _readScore(dynamic value) {
    final score = value is num ? value : num.tryParse(value?.toString() ?? '');
    return score != null && score.isFinite ? score.clamp(0, 100).toInt() : 0;
  }

  static bool _sameList<T>(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
