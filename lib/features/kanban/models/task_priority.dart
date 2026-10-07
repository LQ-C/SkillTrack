enum TaskPriority {
  low('Low'),
  medium('Medium'),
  high('High');

  const TaskPriority(this.label);
  final String label;

  static TaskPriority fromValue(String? value) =>
      TaskPriority.values.firstWhere(
        (priority) => priority.name == value,
        orElse: () => TaskPriority.medium,
      );
}
