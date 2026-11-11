import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../core/errors/app_exception.dart';
import '../models/resource_recommendation.dart';
import '../repositories/bookmark_repository.dart';

class TaskBookmarksViewModel extends ChangeNotifier {
  TaskBookmarksViewModel(this._repository, this.taskId)
    : _owner = _repository.currentUserId {
    _subscription = _repository.userChanges.listen((user) {
      if (!_disposed && user != _owner) {
        _ended = true;
        _items = const [];
        _pending.clear();
        isLoading = false;
        errorMessage = null;
        notifyListeners();
      }
    });
    unawaited(load());
  }
  final BookmarkRepository _repository;
  final String taskId;
  final String? _owner;
  late final StreamSubscription<String?> _subscription;
  bool _disposed = false, _ended = false;
  bool get active =>
      !_disposed &&
      !_ended &&
      _owner != null &&
      _repository.currentUserId == _owner;
  bool isLoading = false;
  bool loaded = false;
  String? errorMessage;
  ResourceRecommendation? _failedWrite;
  Future<void> retry() => _failedWrite == null ? load() : toggle(_failedWrite!);
  List<ResourceRecommendation> _items = const [];
  List<ResourceRecommendation> get items => _items;
  final Set<String> _pending = {};
  bool contains(String id) => _items.any((item) => item.resourceId == id);
  bool busy(String id) => _pending.contains(id);
  Future<void> load() async {
    if (!active || isLoading || _pending.isNotEmpty) return;
    isLoading = true;
    _failedWrite = null;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await _repository.savedResources(taskId);
      if (active) {
        _items = List.unmodifiable(result);
        loaded = true;
      }
    } catch (_) {
      if (active) errorMessage = AppErrorMessages.loadBookmarksFailed;
    } finally {
      if (active) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> toggle(ResourceRecommendation resource) async {
    if (!active || !loaded || isLoading || busy(resource.resourceId)) return;
    final save = !contains(resource.resourceId);
    _pending.add(resource.resourceId);
    _failedWrite = null;
    errorMessage = null;
    notifyListeners();
    // Commit UI state only after success: a failed/uncertain write retains the
    // same desired operation for retry instead of toggling it a second time.
    try {
      await _repository.setBookmark(taskId, resource.resourceId, save);
      if (active) {
        _items = List.unmodifiable(
          save
              ? [..._items, resource]
              : _items.where((item) => item.resourceId != resource.resourceId),
        );
      }
    } catch (_) {
      if (active) {
        _failedWrite = resource;
        errorMessage = AppErrorMessages.saveBookmarkFailed;
      }
    } finally {
      if (active) {
        _pending.remove(resource.resourceId);
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    super.dispose();
  }
}
