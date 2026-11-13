import 'dart:typed_data';

const maxQualificationBytes = 10 * 1024 * 1024;

class QualificationDocument {
  const QualificationDocument(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

/// Check both the extension and file signature before uploading evidence.
String qualificationMime(Uint8List bytes, String fileName) {
  if (bytes.isEmpty || bytes.length > maxQualificationBytes) {
    throw const FormatException(
      'Choose a non-empty qualification document up to 10 MB.',
    );
  }
  final ext = fileName.split('.').last.toLowerCase();
  bool startsWith(List<int> header) =>
      bytes.length >= header.length &&
      Iterable<int>.generate(header.length).every((i) => bytes[i] == header[i]);
  if (ext == 'pdf' && startsWith([37, 80, 68, 70, 45])) {
    return 'application/pdf';
  }
  if (['jpg', 'jpeg'].contains(ext) && startsWith([255, 216, 255])) {
    return 'image/jpeg';
  }
  if (ext == 'png' && startsWith([137, 80, 78, 71, 13, 10, 26, 10])) {
    return 'image/png';
  }
  throw const FormatException(
    'Choose a valid PDF, JPEG or PNG qualification document.',
  );
}
