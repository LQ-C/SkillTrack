import 'package:flutter/material.dart';

import '../../../app/widgets/app_content.dart';
import '../../../app/widgets/card_loading_view.dart';
import '../viewmodels/notification_preferences_view_model.dart';

class NotificationPreferencesScreen extends StatefulWidget {
  const NotificationPreferencesScreen({super.key, required this.viewModel});
  final NotificationPreferencesViewModel viewModel;
  @override
  State<NotificationPreferencesScreen> createState() =>
      _NotificationPreferencesScreenState();
}

class _NotificationPreferencesScreenState
    extends State<NotificationPreferencesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.viewModel.initialize();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) {
      final model = widget.viewModel;
      final theme = Theme.of(context);
      final settings = model.preferences;
      return Scaffold(
        appBar: AppBar(title: const Text('Notification Preferences')),
        body: AppContent(
          child: model.isLoading
              ? const CardLoadingView(label: 'Loading notification preferences')
              : model.errorMessage != null && !model.hasLoaded
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        model.errorMessage!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                      FilledButton(
                        onPressed: model.retry,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : ListTileTheme(
                  data: ListTileTheme.of(context).copyWith(
                    tileColor: theme.colorScheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    titleTextStyle: theme.textTheme.titleMedium,
                    subtitleTextStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (model.errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            model.errorMessage!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      SwitchListTile(
                        title: const Text('Push notifications'),
                        subtitle: const Text(
                          'Receive notifications when SkillTrack is not open.',
                        ),
                        value: settings.pushEnabled,
                        onChanged: model.isSaving ? null : model.setPushEnabled,
                      ),
                      SwitchListTile(
                        title: const Text('Stalled task alerts'),
                        subtitle: const Text(
                          'Notify me when an in-progress task exceeds its inactivity threshold.',
                        ),
                        value: settings.stalledTaskEnabled,
                        onChanged: model.isSaving
                            ? null
                            : model.setStalledTaskEnabled,
                      ),
                      SwitchListTile(
                        title: const Text('Deadline reminders'),
                        subtitle: const Text(
                          'Notify me when a task or project is approaching its deadline.',
                        ),
                        value: settings.deadlineReminderEnabled,
                        onChanged: model.isSaving
                            ? null
                            : model.setDeadlineReminderEnabled,
                      ),
                      SwitchListTile(
                        title: const Text('Learning resource recommendations'),
                        subtitle: const Text(
                          'Notify me when relevant learning resources are found for a stalled task.',
                        ),
                        value: settings.recommendationEnabled,
                        onChanged: model.isSaving
                            ? null
                            : model.setRecommendationEnabled,
                      ),
                    ],
                  ),
                ),
        ),
      );
    },
  );
}
