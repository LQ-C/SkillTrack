class LearningResource {
  const LearningResource({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.title,
    required this.summary,
    required this.category,
    required this.level,
    required this.kind,
    required this.body,
    required this.link,
    required this.tags,
    required this.status,
    this.hidden = false,
    this.attachmentPath,
  });
  final String id,
      authorId,
      authorName,
      title,
      summary,
      category,
      level,
      kind,
      body,
      link,
      status;
  final List<String> tags;
  final bool hidden;
  final String? attachmentPath;
  factory LearningResource.fromJson(Map<String, dynamic> row) =>
      LearningResource(
        id: row['id'] as String,
        authorId: row['author_id'] as String,
        authorName: row['author_name'] as String,
        title: row['title'] as String,
        summary: row['summary'] as String,
        category: row['category'] as String,
        level: row['difficulty'] as String,
        kind: row['kind'] as String,
        body: row['body'] as String? ?? '',
        link: row['external_url'] as String? ?? '',
        tags: List<String>.from(row['tags'] as List? ?? []),
        status: row['status'] as String,
        hidden: row['moderation_hidden'] == true,
        attachmentPath: row['attachment_path'] as String?,
      );
}
