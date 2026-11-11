import '../../../core/utils/date_formatter.dart';

enum TaskGenerationMode { initial, append, replace, revise }

class ExistingTaskSummary {
  const ExistingTaskSummary({
    required this.title,
    required this.status,
    required this.sortOrder,
    this.description = '',
    this.milestoneId,
    this.deadline,
  });

  final String title;
  final String description;
  final String status;
  final DateTime? deadline;
  final int sortOrder;
  final String? milestoneId;

  Map<String, Object?> toRequestJson() {
    final trimmedDescription = description.trim();
    final date = deadline == null
        ? null
        : DateFormatter.malaysiaTime(deadline!);
    return {
      'title': title.trim(),
      'description': trimmedDescription.length <= 500
          ? trimmedDescription
          : trimmedDescription.substring(0, 500),
      'status': status,
      if (milestoneId != null) 'milestoneId': milestoneId,
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
