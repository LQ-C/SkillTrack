enum NotificationType {
  stalledTask('STALLED_TASK'),
  deadlineReminder('DEADLINE_REMINDER'),
  learningResourceRecommendation('LEARNING_RESOURCE_RECOMMENDATION'),
  unknown('UNKNOWN');

  const NotificationType(this.databaseValue);
  final String databaseValue;

  static NotificationType parse(String value) => values.firstWhere(
    (item) => item.databaseValue == value,
    orElse: () => unknown,
  );
}
