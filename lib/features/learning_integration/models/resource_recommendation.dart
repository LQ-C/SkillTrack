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
