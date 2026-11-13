import 'package:file_picker/file_picker.dart';
import '../utils/qualification_file.dart';

Future<QualificationDocument?> pickQualificationDocument() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
  );
  if (file == null) return null;
  final size = await file.length();
  if (size == null || size < 1 || size > maxQualificationBytes) {
    throw const FormatException(
      'Choose a non-empty qualification document up to 10 MB.',
    );
  }
  final bytes = await file.readAsBytes();
  qualificationMime(bytes, file.name);
  return QualificationDocument(file.name, bytes);
}
