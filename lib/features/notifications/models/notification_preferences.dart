import 'package:flutter/foundation.dart';

@immutable
class NotificationPreferences {
  const NotificationPreferences({
    required this.userId,
    this.stalledTaskEnabled = true,
    this.deadlineReminderEnabled = true,
    this.recommendationEnabled = true,
    this.createdAt,
    this.updatedAt,
  });
  final String userId;
  final bool stalledTaskEnabled, deadlineReminderEnabled, recommendationEnabled;
  final DateTime? createdAt, updatedAt;

  factory NotificationPreferences.defaults(String userId) =>
      NotificationPreferences(userId: userId);

  factory NotificationPreferences.fromMap(Map<String, dynamic> map) =>
      NotificationPreferences(
        userId: map['user_id'].toString(),
        stalledTaskEnabled: map['stalled_task_enabled'] != false,
        deadlineReminderEnabled: map['deadline_reminder_enabled'] != false,
        recommendationEnabled: map['recommendation_enabled'] != false,
        createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
        updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? ''),
      );

  Map<String, dynamic> toMap() => {
    'user_id': userId,
    'stalled_task_enabled': stalledTaskEnabled,
    'deadline_reminder_enabled': deadlineReminderEnabled,
    'recommendation_enabled': recommendationEnabled,
  };

  NotificationPreferences copyWith({
    bool? stalledTaskEnabled,
    bool? deadlineReminderEnabled,
    bool? recommendationEnabled,
  }) => NotificationPreferences(
    userId: userId,
    stalledTaskEnabled: stalledTaskEnabled ?? this.stalledTaskEnabled,
    deadlineReminderEnabled:
        deadlineReminderEnabled ?? this.deadlineReminderEnabled,
    recommendationEnabled: recommendationEnabled ?? this.recommendationEnabled,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is NotificationPreferences &&
      userId == other.userId &&
      stalledTaskEnabled == other.stalledTaskEnabled &&
      deadlineReminderEnabled == other.deadlineReminderEnabled &&
      recommendationEnabled == other.recommendationEnabled &&
      createdAt == other.createdAt &&
      updatedAt == other.updatedAt;
  @override
  int get hashCode => Object.hash(
    userId,
    stalledTaskEnabled,
    deadlineReminderEnabled,
    recommendationEnabled,
    createdAt,
    updatedAt,
  );
}
