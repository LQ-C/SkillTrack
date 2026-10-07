class TaskTag {
  static const defaultColorHex = '#5C6BC0';
  static final _hexPattern = RegExp(r'^[0-9A-F]{6}$');

  static String? normalizeHex(String input) {
    final digits = input.trim().replaceFirst(RegExp(r'^#'), '').toUpperCase();
    return _hexPattern.hasMatch(digits) ? '#$digits' : null;
  }

  static bool isValidHex(String input) => normalizeHex(input) != null;

  static String storedColor(String? value) =>
      normalizeHex(value ?? '') ?? defaultColorHex;

  const TaskTag({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.colorHex,
    this.createdAt,
    this.updatedAt,
  });
  final String id, ownerId, name, colorHex;
  final DateTime? createdAt, updatedAt;

  factory TaskTag.fromMap(Map<String, dynamic> map) => TaskTag(
    id: map['id'].toString(),
    ownerId: map['owner_id']?.toString() ?? '',
    name: map['name']?.toString() ?? '',
    colorHex: storedColor(map['color_hex']?.toString()),
    createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
    updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? ''),
  );
  Map<String, dynamic> toMap() => {
    'id': id,
    'owner_id': ownerId,
    'name': name,
    'color_hex': colorHex,
  };
  TaskTag copyWith({
    String? id,
    String? ownerId,
    String? name,
    String? colorHex,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => TaskTag(
    id: id ?? this.id,
    ownerId: ownerId ?? this.ownerId,
    name: name ?? this.name,
    colorHex: colorHex ?? this.colorHex,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      other is TaskTag &&
      id == other.id &&
      ownerId == other.ownerId &&
      name == other.name &&
      colorHex == other.colorHex &&
      createdAt == other.createdAt &&
      updatedAt == other.updatedAt;
  @override
  int get hashCode =>
      Object.hash(id, ownerId, name, colorHex, createdAt, updatedAt);
}
