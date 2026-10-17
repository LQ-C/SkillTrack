enum TaskGenerationMode { initial, append, revise }

class ExistingTaskSummary {
  const ExistingTaskSummary({
    required this.title,
    required this.status,
    required this.sortOrder,
    this.description = '',
    this.deadline,
  });

  final String title;
  final String description;
  final String status;
  final DateTime? deadline;
  final int sortOrder;

  Map<String, Object?> toRequestJson() {
    final trimmedDescription = description.trim();
    final date = deadline;
    return {
      'title': title.trim(),
      'description': trimmedDescription.length <= 500
          ? trimmedDescription
          : trimmedDescription.substring(0, 500),
      'status': status,
      'deadline': date == null
          ? null
          : '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      'sortOrder': sortOrder,
    };
  }
}

String normalizedTaskTitle(String title) => title
    .toLowerCase()
    .trim()
    .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
