enum NotificationContextType {
  task('TASK'),
  project('PROJECT'),
  recommendation('RECOMMENDATION');

  const NotificationContextType(this.databaseValue);
  final String databaseValue;

  static NotificationContextType parse(String value) => values.firstWhere(
    (item) => item.databaseValue == value,
    orElse: () => throw FormatException('Unknown notification context: $value'),
  );
}
