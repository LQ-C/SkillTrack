import 'package:skilltrack/core/utils/view_model.dart';
import 'package:skilltrack/core/errors/content_errors.dart';
import '../models/learning_resource.dart';
import '../repositories/content_repository.dart';

class ContentLibraryViewModel extends ViewModel {
  ContentLibraryViewModel(this.repository);
  final ContentRepository repository;
  String search = '';
  List<LearningResource> resources = [];
  Set<String> bookmarks = {};
  String? category, level, kind, error;
  bool mine = false,
      loading = true,
      more = false,
      mentor = false,
      publisher = false;
  bool accessLoaded = false;
  bool hasAccessibleMaterials = true;
  int request = 0;
  Future<void> load({bool append = false}) async {
    final current = ++request;
    final offset = append ? resources.length : 0;
    update(() {
      loading = true;
      error = null;
    });
    try {
      final access = await repository.permissions();
      if (!isActive || current != request) return;
      update(() {
        mentor = access.mentor;
        mine = mentor;
        publisher = access.publisher;
        accessLoaded = true;
      });
      final saved = await repository.bookmarks();
      final rows = await repository.list(
        mine: mine,
        search: search,
        category: category,
        level: level,
        kind: kind,
        offset: offset,
      );
      var hasMaterials = rows.isNotEmpty;
      final filtered =
          search.trim().isNotEmpty ||
          category != null ||
          level != null ||
          kind != null;
      if (!mentor && !hasMaterials && filtered) {
        // An empty search is different from having no unlocked materials at all.
        final available = await repository.list(
          mine: false,
          search: '',
          offset: 0,
        );
        hasMaterials = available.isNotEmpty;
      }
      if (!isActive || current != request) return;
      update(() {
        bookmarks = saved;
        resources = append ? [...resources, ...rows] : rows;
        more = rows.length == 20;
        if (!append) hasAccessibleMaterials = hasMaterials;
      });
    } catch (e) {
      if (isActive && current == request) {
        update(() => error = contentError(e));
      }
    } finally {
      if (isActive && current == request) update(() => loading = false);
    }
  }
}
