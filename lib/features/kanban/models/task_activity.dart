import 'dart:convert';
import 'dart:collection';

import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';

class TaskActivity {
  static String? validateProgressText(String value) {
    final text = value.trim();
    if (text.isEmpty) return AppErrorMessages.progressUpdateRequired;
    if (text.runes.length > AppLimits.maxProgressUpdateLength) {
      return AppErrorMessages.progressUpdateTooLong;
    }
    return null;
  }

  bool get isProgressUpdate =>
      action == 'updated' &&
      newValues['change'] == 'progress_update' &&
      newValues['progress_text'] is String &&
      validateProgressText(newValues['progress_text'] as String) == null;

  TaskActivity({
    required this.id,
    required this.taskId,
    required this.action,
    required Map<String, dynamic> oldValues,
    required Map<String, dynamic> newValues,
    required this.createdAt,
  }) : oldValues = UnmodifiableMapView(oldValues),
       newValues = UnmodifiableMapView(newValues);
  final String id, taskId, action;
  final Map<String, dynamic> oldValues, newValues;
  final DateTime createdAt;

  factory TaskActivity.fromMap(Map<String, dynamic> map) => TaskActivity(
    id: map['id'].toString(),
    taskId: map['task_id']?.toString() ?? '',
    action: map['action']?.toString() ?? '',
    oldValues: Map<String, dynamic>.from(map['old_values'] as Map? ?? {}),
    newValues: Map<String, dynamic>.from(map['new_values'] as Map? ?? {}),
    createdAt:
        DateTime.tryParse(map['created_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
  Map<String, dynamic> toMap() => {
    'id': id,
    'task_id': taskId,
    'action': action,
    'old_values': oldValues,
    'new_values': newValues,
    'created_at': createdAt.toIso8601String(),
  };
  TaskActivity copyWith({
    String? action,
    Map<String, dynamic>? oldValues,
    Map<String, dynamic>? newValues,
  }) => TaskActivity(
    id: id,
    taskId: taskId,
    action: action ?? this.action,
    oldValues: oldValues ?? this.oldValues,
    newValues: newValues ?? this.newValues,
    createdAt: createdAt,
  );
  @override
  bool operator ==(Object other) =>
      other is TaskActivity &&
      id == other.id &&
      taskId == other.taskId &&
      action == other.action &&
      jsonEncode(oldValues) == jsonEncode(other.oldValues) &&
      jsonEncode(newValues) == jsonEncode(other.newValues) &&
      createdAt == other.createdAt;
  @override
  int get hashCode => Object.hash(
    id,
    taskId,
    action,
    jsonEncode(oldValues),
    jsonEncode(newValues),
    createdAt,
  );
}
