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
