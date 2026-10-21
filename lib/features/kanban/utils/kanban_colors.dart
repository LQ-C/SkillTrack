import 'package:flutter/material.dart';

import '../models/kanban_status.dart';
import '../models/task_priority.dart';

class KanbanColors {
  static Color status(KanbanStatus status) => switch (status) {
    KanbanStatus.todo => const Color(0xFF426A97),
    KanbanStatus.inProgress => const Color(0xFF965A23),
    KanbanStatus.completed => const Color(0xFF2B7656),
  };
  static Color priority(TaskPriority priority) => switch (priority) {
    TaskPriority.low => const Color(0xFF536B78),
    TaskPriority.medium => const Color(0xFF965A23),
    TaskPriority.high => const Color(0xFFB83F4E),
  };
}
