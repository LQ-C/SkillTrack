import 'package:flutter/material.dart';

import '../viewmodels/notification_list_view_model.dart';

class NotificationFilterBar extends StatelessWidget {
  const NotificationFilterBar({
    super.key,
    required this.selected,
    required this.unreadCount,
    required this.onSelected,
  });
  final NotificationListFilter selected;
  final int unreadCount;
  final ValueChanged<NotificationListFilter> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 58,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        for (final filter in NotificationListFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(switch (filter) {
                NotificationListFilter.all => 'All',
                NotificationListFilter.unread =>
                  unreadCount > 0 ? 'Unread $unreadCount' : 'Unread',
                NotificationListFilter.stalled => 'Stalled',
                NotificationListFilter.deadlines => 'Deadlines',
                NotificationListFilter.resources => 'Resources',
              }),
              selected: filter == selected,
              onSelected: (_) => onSelected(filter),
            ),
          ),
      ],
    ),
  );
}
