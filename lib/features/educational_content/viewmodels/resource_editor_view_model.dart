import 'dart:typed_data';

import 'package:skilltrack/core/utils/view_model.dart';
import 'package:skilltrack/core/errors/content_errors.dart';
import '../repositories/content_repository.dart';

class ResourceEditorViewModel extends ViewModel {
  ResourceEditorViewModel(this.repository);
  final ContentRepository repository;
  bool busy = false;
  String? error;
  Future<bool> save(
    Map<String, dynamic> values, {
    String? id,
    ({String name, Uint8List bytes})? attachment,
  }) async {
    if (busy) return false;
    update(() {
      busy = true;
      error = null;
    });
    try {
      if (attachment == null) {
        await repository.save(values, id: id);
      } else {
        await (repository as ResourceFileRepository).saveResourceFile(
          values,
          attachment.name,
          attachment.bytes,
          id: id,
        );
      }
      return true;
    } catch (e) {
      update(() => error = contentError(e));
      return false;
    } finally {
      update(() => busy = false);
    }
  }
}
