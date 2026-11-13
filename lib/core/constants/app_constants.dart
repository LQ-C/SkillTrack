class AppLimits {
  static const maxProgressUpdateLength = 1000;
  static const maxMilestoneTitleLength = 150;
  static const maxGeneratedMilestones = 5;
  static const maxTaskGenerationConstraintsLength = 1000;
  static const maxAttachmentBytes = 10 * 1024 * 1024;
}

class PushPermissionMessages {
  static const title = 'Stay on track';
  static const enable = 'Enable Notifications';
  static const notNow = 'Not Now';
  static const settings = 'Open Settings';
  static const explanation =
      'Get task reminders and learning updates even when SkillTrack is closed. Enable Notifications turns on push for this account after Android permission and device registration succeed. You can change this in Notification Preferences.';
  static const settingsExplanation =
      'Notifications are off in Android Settings. Allow them there to enable push for this account. In-app notifications remain available.';
  static const denied =
      'Notification permission was denied. Allow notifications in Android settings to enable push.';
  static const settingsRequired =
      'Notification permission is off. Open Android Settings to allow notifications, then enable push here.';
}
