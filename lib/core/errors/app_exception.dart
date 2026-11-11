class AppException implements Exception {
  const AppException(this.message);
  final String message;
  static String messageFor(
    Object error, {
    String fallback = AppErrorMessages.requestFailed,
  }) => error is AppException ? error.message : fallback;
  @override
  String toString() => message;
}

class AppErrorMessages {
  static const loadRecommendationsFailed =
      'Unable to load learning resources. Please try again.';
  static const deadlineDatePassed = 'Choose today or a future date.';
  static const deadlineTimePassed = 'Choose a time later than now.';
  static const progressUpdateRequired = 'Enter a progress update.';
  static const progressUpdateTooLong = 'Use 1000 characters or fewer.';
  static const saveProgressUpdateFailed =
      'Unable to save your progress update. Check your connection and try again.';
  static const milestoneNameRequired = 'Enter a milestone name.';
  static const milestoneNameTooLong = 'Use 150 characters or fewer.';
  static const createMilestoneFailed =
      'Unable to create the milestone. Check your connection and try again.';
  static const milestoneBoardUnavailable =
      'Use an active project board you own. Refresh the board and try again.';
  static const taskSetupIncomplete =
      'Task setup is incomplete. Please contact support.';
  static const invalidMilestone =
      'Choose a valid milestone with a name of 1–150 characters.';
  static const milestoneReorder =
      'Reorder within a milestone, or use Edit to change its milestone.';
  static const invalidGenerationConstraints =
      'Constraints must be 1000 characters or fewer.';
  static const taskChanged = 'Task changed. Refresh it and try again.';
  static const updateTaskTimerFailed =
      'Unable to update the timer. Please try again.';
  static const attachmentTooLarge =
      'Choose a non-empty file of 10 MB or smaller.';
  static const savedRefreshFailed =
      'Changes saved. Unable to refresh the board. Please refresh to see updates.';
  static const olderNotificationsFailed = 'Unable to load older notifications.';
  static const invalidNotificationCursor = 'Invalid notification cursor.';
  static const requestFailed =
      'Unable to complete the request. Please check your connection.';
  static const signInFailed =
      'Unable to sign in. Please check your credentials and try again.';
  static const storageFailed =
      'Unable to access attachment storage. Please try again.';
  static const credentialsRequired = 'Enter your email and password.';
  static const invalidTagColor = 'Enter a valid 6-digit hex color.';
  static const createProjectFailed =
      'Unable to create the project. Please try again.';
  static const generateTasksFailed =
      'Tasks could not be generated. Please try again.';
  static const taskGenerationTimedOut =
      'Task generation is taking too long. Please try again.';
  static const taskGenerationUnavailable =
      'Task generation is unavailable right now. Create an empty project or try again later.';
  static const noGeneratedTasks =
      'No valid tasks were generated. Please try again.';
  static const invalidGeneratedDraft =
      'Check each task title, description, priority, and deadline.';
  static const duplicateGeneratedTitle =
      'Generated task titles must be unique.';
  static const invalidGeneratedChecklist =
      'Check the checklist items. Use up to five unique items of 150 characters or fewer.';
  static const invalidRevisionFeedback =
      'Enter revision feedback of 1000 characters or fewer.';
  static const noAdditionalTasks = 'No new tasks were found for this project.';
  static const additionalTasksAlreadyExist =
      'No new tasks were added because they already exist.';
  static const expiredProjectDeadline =
      'Update the project end date before generating more tasks.';
  static const projectDescriptionRequired =
      'Add a project description before generating more tasks.';
  static const addGeneratedTasksFailed =
      'Unable to add tasks. Please try again.';
  static const saveGeneratedTasksFailed =
      'The project was created, but the generated tasks could not be saved. Please retry or open the empty project.';
  static const updateProjectFailed =
      'Unable to update the project. Please try again.';
  static const saveTagFailed = 'Unable to save the tag. Please try again.';
  static const deleteTagFailed = 'Unable to delete the tag. Please try again.';
  static const updateNotificationsFailed =
      'Unable to update notifications. Please try again.';
  static const loadNotificationsFailed = 'Unable to load notifications';
  static const loadArchivedTasksFailed = 'Unable to load archived tasks';
  static const resumeTaskFailed =
      'Unable to resume the task. Please try again.';
}
