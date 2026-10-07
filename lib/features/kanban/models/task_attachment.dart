class TaskAttachment {
  const TaskAttachment({
    required this.id,
    required this.taskId,
    required this.fileName,
    required this.storagePath,
    this.mimeType,
    this.fileSizeBytes,
    this.createdAt,
  });
  final String id, taskId, fileName, storagePath;
  final String? mimeType;
  final int? fileSizeBytes;
  final DateTime? createdAt;

  factory TaskAttachment.fromMap(Map<String, dynamic> map) => TaskAttachment(
    id: map['id'].toString(),
    taskId: map['task_id']?.toString() ?? '',
    fileName: map['file_name']?.toString() ?? '',
    storagePath: map['storage_path']?.toString() ?? '',
    mimeType: map['mime_type']?.toString(),
    fileSizeBytes: (map['file_size_bytes'] as num?)?.toInt(),
    createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
  );
  Map<String, dynamic> toMap() => {
    'id': id,
    'task_id': taskId,
    'file_name': fileName,
    'storage_path': storagePath,
    'mime_type': mimeType,
    'file_size_bytes': fileSizeBytes,
  };
  TaskAttachment copyWith({
    String? fileName,
    String? storagePath,
    String? mimeType,
    int? fileSizeBytes,
  }) => TaskAttachment(
    id: id,
    taskId: taskId,
    fileName: fileName ?? this.fileName,
    storagePath: storagePath ?? this.storagePath,
    mimeType: mimeType ?? this.mimeType,
    fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
    createdAt: createdAt,
  );
  @override
  bool operator ==(Object other) =>
      other is TaskAttachment &&
      id == other.id &&
      taskId == other.taskId &&
      fileName == other.fileName &&
      storagePath == other.storagePath &&
      mimeType == other.mimeType &&
      fileSizeBytes == other.fileSizeBytes &&
      createdAt == other.createdAt;
  @override
  int get hashCode => Object.hash(
    id,
    taskId,
    fileName,
    storagePath,
    mimeType,
    fileSizeBytes,
    createdAt,
  );
}
