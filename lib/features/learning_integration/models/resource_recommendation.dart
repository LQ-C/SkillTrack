class ResourceRecommendation {
  const ResourceRecommendation({
    required this.resourceId,
    required this.title,
    required this.summary,
    required this.type,
  });
  final String resourceId;
  final String title;
  final String summary;
  final String type;

  factory ResourceRecommendation.fromMap(Map<String, dynamic> map) {
    final id = map['resource_id'];
    final title = map['title'];
    final summary = map['summary'];
    final type = map['type'];
    if (id is! String ||
        id.isEmpty ||
        title is! String ||
        title.trim().isEmpty ||
        summary is! String ||
        type is! String) {
      throw const FormatException('Invalid recommendation');
    }
    return ResourceRecommendation(
      resourceId: id,
      title: title,
      summary: summary,
      type: type,
    );
  }
}

class SavedTaskRecommendations {
  const SavedTaskRecommendations({
    required this.generated,
    required this.items,
    this.stalledAt,
  });
  final bool generated;
  final List<ResourceRecommendation> items;
  final DateTime? stalledAt;
  factory SavedTaskRecommendations.fromMap(Map<String, dynamic> map) {
    if (map['generated'] is! bool || map['recommendations'] is! List) {
      throw const FormatException('Invalid saved recommendations');
    }
    return SavedTaskRecommendations(
      generated: map['generated'] as bool,
      stalledAt: DateTime.tryParse(map['stalled_at']?.toString() ?? ''),
      items: List.unmodifiable(
        (map['recommendations'] as List).map(
          (row) => ResourceRecommendation.fromMap(
            Map<String, dynamic>.from(row as Map),
          ),
        ),
      ),
    );
  }
}
