import 'package:flutter/foundation.dart';

import 'notification_context_type.dart';
import 'notification_type.dart';

@immutable
class AppNotification {
  AppNotification({
    required this.id,
    required this.userId,
    required this.type,
    required this.contextType,
    this.projectId,
    this.boardId,
    this.taskId,
    required this.title,
    required this.message,
    this.isRead = false,
    this.readAt,
    Map<String, dynamic> actionData = const {},
    this.uniqueKey,
    required this.createdAt,
  }) : actionData = Map.unmodifiable(actionData);

  final String id, userId, title, message;
  final NotificationType type;
  final NotificationContextType contextType;
  final String? projectId, boardId, taskId, uniqueKey;
  final bool isRead;
  final DateTime? readAt;
  final Map<String, dynamic> actionData;
  final DateTime createdAt;

  bool get isUnread => !isRead;
  bool get hasTaskContext => taskId?.isNotEmpty == true;
  bool get hasProjectContext => projectId?.isNotEmpty == true;
  bool get canNavigate => contextType == NotificationContextType.project
      ? hasProjectContext
      : hasProjectContext && hasTaskContext;

  factory AppNotification.fromMap(Map<String, dynamic> map) => AppNotification(
    id: map['id'].toString(),
    userId: map['user_id'].toString(),
    type: NotificationType.parse(map['type'].toString()),
    contextType: NotificationContextType.parse(map['context_type'].toString()),
    projectId: map['project_id']?.toString(),
    boardId: map['board_id']?.toString(),
    taskId: map['task_id']?.toString(),
    title: map['title'].toString(),
    message: map['message'].toString(),
    isRead: map['is_read'] == true,
    readAt: DateTime.tryParse(map['read_at']?.toString() ?? ''),
    actionData: Map<String, dynamic>.from(map['action_data'] as Map? ?? {}),
    uniqueKey: map['unique_key']?.toString(),
    createdAt: DateTime.parse(map['created_at'].toString()).toUtc(),
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'user_id': userId,
    'type': type.databaseValue,
    'context_type': contextType.databaseValue,
    'project_id': projectId,
    'board_id': boardId,
    'task_id': taskId,
    'title': title,
    'message': message,
    'is_read': isRead,
    'read_at': readAt?.toUtc().toIso8601String(),
    'action_data': actionData,
    'unique_key': uniqueKey,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  AppNotification copyWith({bool? isRead, DateTime? readAt}) => AppNotification(
    id: id,
    userId: userId,
    type: type,
    contextType: contextType,
    projectId: projectId,
    boardId: boardId,
    taskId: taskId,
    title: title,
    message: message,
    isRead: isRead ?? this.isRead,
    readAt: readAt ?? this.readAt,
    actionData: actionData,
    uniqueKey: uniqueKey,
    createdAt: createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is AppNotification &&
      id == other.id &&
      userId == other.userId &&
      type == other.type &&
      contextType == other.contextType &&
      projectId == other.projectId &&
      boardId == other.boardId &&
      taskId == other.taskId &&
      title == other.title &&
      message == other.message &&
      isRead == other.isRead &&
      readAt == other.readAt &&
      mapEquals(actionData, other.actionData) &&
      uniqueKey == other.uniqueKey &&
      createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    userId,
    type,
    contextType,
    projectId,
    boardId,
    taskId,
    title,
    message,
    isRead,
    readAt,
    Object.hashAllUnordered(
      actionData.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    uniqueKey,
    createdAt,
  );
}
