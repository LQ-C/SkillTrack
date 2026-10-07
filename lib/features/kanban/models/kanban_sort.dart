enum KanbanSort {
  custom('Custom order'),
  nearestDeadline('Nearest deadline'),
  highestPriority('Highest priority'),
  recentlyCreated('Recently created'),
  recentlyUpdated('Recently updated');

  const KanbanSort(this.label);
  final String label;
}
