enum KanbanStatus {
  todo('todo', 'To-Do'),
  inProgress('in_progress', 'In Progress'),
  completed('completed', 'Completed');

  const KanbanStatus(this.value, this.label);
  final String value;
  final String label;

  static KanbanStatus fromValue(String? value) =>
      KanbanStatus.values.firstWhere(
        (status) => status.value == value,
        orElse: () => KanbanStatus.todo,
      );
}
