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
