import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../models/kanban_status.dart';
import '../models/task_priority.dart';

class KanbanColors {
  static Color status(KanbanStatus status) => switch (status) {
    KanbanStatus.todo => const Color(0xFF607D8B),
    KanbanStatus.inProgress => const Color(0xFFB66A00),
    KanbanStatus.completed => const Color(0xFF22835A),
  };
  static Color priority(TaskPriority priority) => switch (priority) {
    TaskPriority.low => const Color(0xFF546E7A),
    TaskPriority.medium => AppColors.warning,
    TaskPriority.high => const Color(0xFFC23638),
  };
}
