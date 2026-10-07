import 'package:flutter/material.dart';

import '../../features/kanban/models/kanban_status.dart';
import '../../features/kanban/models/task_priority.dart';

class AppColors {
  static Color status(KanbanStatus status) => switch (status) {
    KanbanStatus.todo => const Color(0xFF607D8B),
    KanbanStatus.inProgress => const Color(0xFFB66A00),
    KanbanStatus.completed => const Color(0xFF22835A),
  };
  static Color priority(TaskPriority priority) => switch (priority) {
    TaskPriority.low => const Color(0xFF546E7A),
    TaskPriority.medium => const Color(0xFFAE6800),
    TaskPriority.high => const Color(0xFFC23638),
  };
}
