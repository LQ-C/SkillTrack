import 'package:skilltrack/core/utils/view_model.dart';
import 'package:skilltrack/core/errors/content_errors.dart';
import '../models/learning_resource.dart';
import '../repositories/content_repository.dart';

class ResourceDetailViewModel extends ViewModel {
  ResourceDetailViewModel(this.repository, this.id, {required this.bookmarked});
  final ContentRepository repository;
  final String id;
  LearningResource? resource;
  bool loading = true, busy = false, bookmarked;
  String? error, success;
  Future<void> load() async {
    update(() {
      loading = true;
      error = null;
    });
    try {
      final value = await repository.get(id);
      update(() => resource = value);
    } catch (e) {
      update(() {
        resource = null;
        error = contentError(e);
      });
    } finally {
      update(() => loading = false);
    }
  }

  Future<void> action(Future<void> Function() work) async {
    if (busy) return;
    update(() {
      busy = true;
      error = null;
      success = null;
    });
    try {
      await work();
    } catch (e) {
      update(() => error = contentError(e));
    } finally {
      update(() => busy = false);
    }
  }

  Future<void> toggleBookmark() => action(() async {
    await repository.bookmark(id, !bookmarked);
    update(() => bookmarked = !bookmarked);
  });
  Future<void> report(String reason, String details) => action(() async {
    await repository.report(id, reason, details);
    update(() => success = 'Report submitted for review. Thank you.');
  });
}
