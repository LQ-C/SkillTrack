import '../../../core/errors/app_exception.dart';

/// Unpersisted, validated input from the task generator.
class GeneratedTaskDraft {
  GeneratedTaskDraft({
    required this.title,
    required this.description,
    required this.priority,
    required this.deadline,
    required this.position,
    List<String> checklist = const [],
  }) : checklist = List.unmodifiable(checklist);

  final String title;
  final String description;
  final String priority;
  final DateTime deadline;
  final int position;
  final List<String> checklist;

  static List<GeneratedTaskDraft> parseTasks(
    Object? response, {
    required DateTime startDate,
    required DateTime endDate,
  }) {
    if (response is! Map || response['milestones'] is! List) {
      throw const AppException(AppErrorMessages.noGeneratedTasks);
    }
    final seen = <String>{};
    final candidates =
        <
          ({
            String title,
            String description,
            String priority,
            List<String> checklist,
          })
        >[];
    for (final milestone in response['milestones'] as List) {
      if (milestone is! Map || milestone['tasks'] is! List) continue;
      for (final row in milestone['tasks'] as List) {
        if (row is! Map) continue;
        final title = (row['title'] is String ? row['title'] as String : '')
            .trim();
        if (title.isEmpty) continue;
        final safeTitle = title.length > 150 ? title.substring(0, 150) : title;
        if (!seen.add(safeTitle.toLowerCase())) continue;
        final rawDescription =
            (row['description'] is String ? row['description'] as String : '')
                .trim();
        candidates.add((
          title: safeTitle,
          description: rawDescription.length > 1000
              ? rawDescription.substring(0, 1000)
              : rawDescription,
          priority: switch (row['priority']) {
            String value when value.trim().toLowerCase() == 'low' => 'low',
            String value when value.trim().toLowerCase() == 'high' => 'high',
            _ => 'medium',
          },
          checklist: _parseChecklist(row['checklist']),
        ));
        if (candidates.length == 12) break;
      }
      if (candidates.length == 12) break;
    }
    if (candidates.length < 3) {
      throw const AppException(AppErrorMessages.noGeneratedTasks);
    }
    final days = DateTime.utc(endDate.year, endDate.month, endDate.day)
        .difference(
          DateTime.utc(startDate.year, startDate.month, startDate.day),
        )
        .inDays;
    return [
      for (var index = 0; index < candidates.length; index++)
        GeneratedTaskDraft(
          title: candidates[index].title,
          description: candidates[index].description,
          priority: candidates[index].priority,
          deadline: DateTime(
            startDate.year,
            startDate.month,
            startDate.day + (days * index / (candidates.length - 1)).round(),
          ),
          position: index,
          checklist: candidates[index].checklist,
        ),
    ];
  }

  static List<String> _parseChecklist(Object? value) {
    if (value is! List) return const [];
    final seen = <String>{};
    final items = <String>[];
    for (final entry in value) {
      if (entry is! String) continue;
      final trimmed = entry.trim();
      final title = trimmed.length > 150 ? trimmed.substring(0, 150) : trimmed;
      if (title.isEmpty || !seen.add(title.toLowerCase())) continue;
      items.add(title);
      if (items.length == 5) break;
    }
    return items;
  }
}
