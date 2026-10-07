class TaskChecklistItem {
  const TaskChecklistItem({
    required this.id,
    required this.taskId,
    required this.title,
    required this.isCompleted,
    required this.position,
    this.completedAt,
    this.createdAt,
    this.updatedAt,
  });
  final String id, taskId, title;
  final bool isCompleted;
  final int position;
  final DateTime? completedAt, createdAt, updatedAt;

  factory TaskChecklistItem.fromMap(Map<String, dynamic> map) =>
      TaskChecklistItem(
        id: map['id'].toString(),
        taskId: map['task_id']?.toString() ?? '',
        title: map['title']?.toString() ?? '',
        isCompleted: map['is_completed'] == true,
        position: (map['position'] as num?)?.toInt() ?? 0,
        completedAt: DateTime.tryParse(map['completed_at']?.toString() ?? ''),
        createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
        updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? ''),
      );
  Map<String, dynamic> toMap() => {
    'id': id,
    'task_id': taskId,
    'title': title,
    'is_completed': isCompleted,
    'position': position,
    'completed_at': completedAt?.toIso8601String(),
  };
  TaskChecklistItem copyWith({
    String? title,
    bool? isCompleted,
    int? position,
    DateTime? completedAt,
    bool clearCompletedAt = false,
  }) => TaskChecklistItem(
    id: id,
    taskId: taskId,
    title: title ?? this.title,
    isCompleted: isCompleted ?? this.isCompleted,
    position: position ?? this.position,
    completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      other is TaskChecklistItem &&
      id == other.id &&
      taskId == other.taskId &&
      title == other.title &&
      isCompleted == other.isCompleted &&
      position == other.position &&
      completedAt == other.completedAt &&
      createdAt == other.createdAt &&
      updatedAt == other.updatedAt;
  @override
  int get hashCode => Object.hash(
    id,
    taskId,
    title,
    isCompleted,
    position,
    completedAt,
    createdAt,
    updatedAt,
  );
}
