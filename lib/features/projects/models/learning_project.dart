class LearningProject {
  const LearningProject({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.status,
    this.description,
    this.constraints,
    this.startDate,
    this.endDate,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String ownerId;
  final String name;
  final String status;
  final String? description;
  final String? constraints;
  final DateTime? startDate;
  final DateTime? endDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  static String? normalizeConstraints(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  factory LearningProject.fromMap(Map<String, dynamic> map) => LearningProject(
    id: map['id'].toString(),
    ownerId: map['owner_id'].toString(),
    name: map['name'] as String,
    description: map['description'] as String?,
    constraints: normalizeConstraints(map['constraints_text'] as String?),
    status: map['status'] as String? ?? 'active',
    startDate: DateTime.tryParse(map['start_date']?.toString() ?? ''),
    endDate: DateTime.tryParse(map['end_date']?.toString() ?? ''),
    createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
    updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? ''),
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'owner_id': ownerId,
    'name': name,
    'description': description,
    'constraints_text': normalizeConstraints(constraints),
    'status': status,
    'start_date': startDate?.toIso8601String().split('T').first,
    'end_date': endDate?.toIso8601String().split('T').first,
  };

  LearningProject copyWith({
    String? name,
    String? status,
    String? description,
    String? constraints,
    bool clearConstraints = false,
    bool clearDescription = false,
    DateTime? startDate,
    bool clearStartDate = false,
    DateTime? endDate,
    bool clearEndDate = false,
  }) => LearningProject(
    id: id,
    ownerId: ownerId,
    name: name ?? this.name,
    status: status ?? this.status,
    description: clearDescription ? null : description ?? this.description,
    constraints: clearConstraints
        ? null
        : normalizeConstraints(constraints ?? this.constraints),
    startDate: clearStartDate ? null : startDate ?? this.startDate,
    endDate: clearEndDate ? null : endDate ?? this.endDate,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}
