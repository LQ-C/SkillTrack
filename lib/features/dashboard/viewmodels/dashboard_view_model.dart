import 'dart:async';
import 'package:skilltrack/core/utils/view_model.dart';
import '../../tutor_management/models/tutor_models.dart';
import '../repositories/dashboard_repository.dart';

class DashboardViewModel extends ViewModel {
  DashboardViewModel(this.loadProfile, {this.repository}) {
    _owner = repository?.userId;
    _subscription = repository?.userChanges.listen((id) {
      if (id == _owner) return;
      _owner = id;
      _epoch++;
      _pending.clear();
      update(() {
        name = null;
        role = null;
        projects = null;
        session = null;
        errors.clear();
      });
      if (id != null) unawaited(load());
    });
  }
  final Future<Map<String, dynamic>> Function() loadProfile;
  final DashboardRepository? repository;
  StreamSubscription<String?>? _subscription;
  String? _owner, name, role;
  int _epoch = 0;
  final _pending = <String, Future<void>>{};
  final errors = <String>{};
  DashboardProjects? projects;
  MentorshipSession? session;
  bool get loading => _pending.isNotEmpty;
  bool get failed => errors.contains('profile');
  bool busy(String section) => _pending.containsKey(section);
  Future<void> load() async => Future.wait(
    [
      'profile',
      if (repository != null) ...['projects', 'session'],
    ].map(retry),
  );
  Future<void> retry(String section) {
    if (_pending.containsKey(section)) return _pending[section]!;
    final epoch = _epoch;
    final owner = repository?.userId;
    bool valid() => isActive && epoch == _epoch && owner == repository?.userId;
    final future = Future<void>(() async {
      try {
        switch (section) {
          case 'profile':
            final data = await loadProfile();
            if (valid()) {
              name = data['full_name'] as String?;
              role = data['role'] as String?;
            }
          case 'projects':
            final now = DateTime.now();
            final data = await repository!.projects(now);
            if (valid()) {
              projects = data;
            }
          case 'session':
            final data = await repository!.session(DateTime.now());
            if (valid()) session = data;
        }
        if (valid()) errors.remove(section);
      } catch (_) {
        if (valid()) errors.add(section);
      } finally {
        if (valid()) update(() => _pending.remove(section));
      }
    });
    _pending[section] = future;
    update(() {});
    return future;
  }

  @override
  void dispose() {
    _epoch++;
    _subscription?.cancel();
    super.dispose();
  }
}
