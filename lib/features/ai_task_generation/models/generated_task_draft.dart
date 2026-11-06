import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/utils/operation_id.dart';
import '../../projects/models/project_milestone.dart';
import 'generated_milestone_draft.dart';
import 'task_generation_request.dart';

/// Unpersisted, validated input from the task generator.
class GeneratedTaskDraft {
  GeneratedTaskDraft({
    required this.title,
    required this.description,
    required this.priority,
    required this.deadline,
    required this.position,
    List<String> checklist = const [],
    this.milestone,
    String? localId,
  }) : localId = localId ?? createOperationId(),
       checklist = List.unmodifiable(checklist);

  final String localId;
  final String title;
  final String description;
  final String priority;
  final DateTime deadline;
  final int position;
  final List<String> checklist;
  final GeneratedMilestoneDraft? milestone;

  GeneratedTaskDraft copyWith({
    String? title,
    String? description,
    String? priority,
    DateTime? deadline,
    int? position,
    List<String>? checklist,
    GeneratedMilestoneDraft? milestone,
    bool clearMilestone = false,
  }) => GeneratedTaskDraft(
    localId: localId,
    title: title ?? this.title,
    description: description ?? this.description,
    priority: priority ?? this.priority,
    deadline: deadline ?? this.deadline,
    position: position ?? this.position,
    checklist: checklist ?? this.checklist,
    milestone: clearMilestone ? null : milestone ?? this.milestone,
  );

  Map<String, Object?> toRevisionJson() => {
    'title': title.trim(),
    'description': description.trim(),
    'priority': priority.trim(),
    'deadline':
        '${deadline.year.toString().padLeft(4, '0')}-${deadline.month.toString().padLeft(2, '0')}-${deadline.day.toString().padLeft(2, '0')}',
    'position': position,
    if (milestone != null) 'milestone': milestone!.toJson(),
    if (milestone != null) 'draftTaskId': localId,
    'checklist': [for (final item in checklist) item.trim()],
  };

  static List<GeneratedTaskDraft> reindex(List<GeneratedTaskDraft> drafts) => [
    for (var index = 0; index < drafts.length; index++)
      drafts[index].copyWith(position: index),
  ];

  static List<GeneratedTaskDraft> grouped(List<GeneratedTaskDraft> tasks) {
    final groups = <String?, List<GeneratedTaskDraft>>{};
    for (final task in tasks) {
      (groups[task.milestone?.localId] ??= []).add(task);
    }
    return reindex([for (final group in groups.values) ...group]);
  }

  static String? validationError(
    List<GeneratedTaskDraft> drafts, {
    required DateTime startDate,
    required DateTime endDate,
    Iterable<String> existingTitles = const [],
  }) {
    if (drafts.isEmpty) return AppErrorMessages.noGeneratedTasks;
    final groups = <String, GeneratedMilestoneDraft>{};
    for (final task in drafts) {
      final group = task.milestone;
      if (group == null) continue;
      if (group.localId.isEmpty ||
          group.localId.length > 128 ||
          group.title.trim().isEmpty ||
          group.title.length > AppLimits.maxMilestoneTitleLength ||
          group.position < 0) {
        return AppErrorMessages.invalidMilestone;
      }
      final previous = groups[group.localId];
      if (previous != null &&
          (previous.title != group.title ||
              previous.position != group.position ||
              previous.existingMilestoneId != group.existingMilestoneId)) {
        return AppErrorMessages.invalidMilestone;
      }
      groups[group.localId] = group;
    }
    if (groups.length > AppLimits.maxGeneratedMilestones ||
        drafts.length > 12) {
      return AppErrorMessages.invalidMilestone;
    }
    final titles = existingTitles.map(normalizedTaskTitle).toSet();
    final first = DateTime(startDate.year, startDate.month, startDate.day);
    final last = DateTime(endDate.year, endDate.month, endDate.day);
    for (final draft in drafts) {
      final title = draft.title.trim();
      final description = draft.description.trim();
      final date = DateTime(
        draft.deadline.year,
        draft.deadline.month,
        draft.deadline.day,
      );
      if (title.isEmpty ||
          title.length > 150 ||
          description.isEmpty ||
          description.length > 1000 ||
          !const {'low', 'medium', 'high'}.contains(draft.priority) ||
          date.isBefore(first) ||
          date.isAfter(last)) {
        return AppErrorMessages.invalidGeneratedDraft;
      }
      if (!titles.add(normalizedTaskTitle(title))) {
        return AppErrorMessages.duplicateGeneratedTitle;
      }
      if (draft.checklist.length > 5 ||
          draft.checklist.any(
            (item) => item.trim().isEmpty || item.trim().length > 150,
          ) ||
          draft.checklist
                  .map((item) => item.trim().toLowerCase())
                  .toSet()
                  .length !=
              draft.checklist.length) {
        return AppErrorMessages.invalidGeneratedChecklist;
      }
    }
    return null;
  }

  static List<GeneratedTaskDraft> parseTasks(
    Object? response, {
    required DateTime startDate,
    required DateTime endDate,
    int minimumTaskCount = 3,
    Map<String, DateTime> preservedDeadlines = const {},
    List<GeneratedTaskDraft> previousDraft = const [],
    List<ProjectMilestone> existingMilestones = const [],
  }) {
    if (response is! Map ||
        response['milestones'] is! List ||
        (response['milestones'] as List).length >
            AppLimits.maxGeneratedMilestones) {
      throw const AppException(AppErrorMessages.noGeneratedTasks);
    }
    final seen = <String>{};
    final seenGroups = <String>{};
    final seenTaskIds = <String>{};
    final known = {for (final group in existingMilestones) group.id: group};
    final previousGroups = {
      for (final task in previousDraft)
        if (task.milestone != null) task.milestone!.localId: task.milestone!,
    };
    var groupPosition = 0;
    final candidates =
        <
          ({
            String title,
            String description,
            String priority,
            DateTime? deadline,
            List<String> checklist,
            GeneratedMilestoneDraft milestone,
            String? taskId,
          })
        >[];
    for (final milestone in response['milestones'] as List) {
      if (milestone is! Map || milestone['tasks'] is! List) continue;
      final rawExisting = milestone['existingMilestoneId'];
      final existingId = rawExisting is String && rawExisting.trim().isNotEmpty
          ? rawExisting.trim()
          : null;
      if (existingId != null && !known.containsKey(existingId)) {
        throw const AppException(AppErrorMessages.invalidMilestone);
      }
      final rawTitle = milestone['title'] is String
          ? (milestone['title'] as String).trim()
          : '';
      final title = existingId == null
          ? (rawTitle.isEmpty ? 'Milestone ${groupPosition + 1}' : rawTitle)
          : known[existingId]!.title;
      var localId = existingId == null && milestone['localId'] is String
          ? (milestone['localId'] as String).trim()
          : '';
      if (existingId != null) localId = 'saved:$existingId';
      if (localId.isEmpty) {
        final old = previousDraft
            .where(
              (old) =>
                  old.milestone != null &&
                  (milestone['tasks'] as List).any(
                    (row) =>
                        row is Map &&
                        normalizedTaskTitle(row['title']?.toString() ?? '') ==
                            normalizedTaskTitle(old.title),
                  ),
            )
            .map((task) => task.milestone!)
            .firstOrNull;
        localId = old?.localId ?? createOperationId();
      }
      if (!seenGroups.add(localId) ||
          localId.length > 128 ||
          title.length > AppLimits.maxMilestoneTitleLength) {
        throw const AppException(AppErrorMessages.invalidMilestone);
      }
      // Keep the same identity when a revision renames an existing draft group.
      final previous = previousGroups[localId];
      if (previous != null && previous.existingMilestoneId != existingId) {
        throw const AppException(AppErrorMessages.invalidMilestone);
      }
      final group = GeneratedMilestoneDraft(
        localId: localId,
        title: title,
        position: groupPosition++,
        existingMilestoneId: existingId,
      );
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
        final taskId = previousDraft
            .where(
              (old) =>
                  old.localId == row['draftTaskId'] ||
                  normalizedTaskTitle(old.title) ==
                      normalizedTaskTitle(safeTitle),
            )
            .firstOrNull
            ?.localId;
        if (taskId != null && !seenTaskIds.add(taskId)) {
          throw const AppException(AppErrorMessages.invalidGeneratedDraft);
        }
        candidates.add((
          taskId: taskId,
          milestone: group,
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
          deadline:
              _parseDeadline(row['deadline'], startDate, endDate) ??
              preservedDeadlines[normalizedTaskTitle(safeTitle)],
        ));
        if (candidates.length == 12) break;
      }
      if (candidates.length == 12) break;
    }
    if (candidates.length < minimumTaskCount) {
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
          localId: candidates[index].taskId,
          title: candidates[index].title,
          description: candidates[index].description,
          priority: candidates[index].priority,
          deadline:
              candidates[index].deadline ??
              DateTime(
                startDate.year,
                startDate.month,
                startDate.day +
                    (candidates.length == 1
                        ? 0
                        : (days * index / (candidates.length - 1)).round()),
              ),
          position: index,
          checklist: candidates[index].checklist,
          milestone: candidates[index].milestone,
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

  static DateTime? _parseDeadline(Object? value, DateTime start, DateTime end) {
    if (value is! String ||
        !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(value)) {
      return null;
    }
    final date = DateTime.tryParse(value);
    if (date == null || date.toIso8601String().substring(0, 10) != value) {
      return null;
    }
    final first = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    return date.isBefore(first) || date.isAfter(last) ? null : date;
  }
}
