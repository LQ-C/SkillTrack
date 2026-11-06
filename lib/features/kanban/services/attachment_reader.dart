import 'dart:typed_data';

import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';

Future<Uint8List> readTaskAttachment(
  Stream<List<int>>? stream, {
  required int declaredSize,
}) async {
  const limit = AppLimits.maxAttachmentBytes;
  const tooLarge = AppException(AppErrorMessages.attachmentTooLarge);
  if (declaredSize > limit) throw tooLarge;
  if (stream == null) throw StateError('File data unavailable');

  final buffer = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > limit - buffer.length) throw tooLarge;
    buffer.add(chunk);
  }
  return buffer.takeBytes();
}
