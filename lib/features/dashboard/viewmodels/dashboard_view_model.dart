import 'package:skilltrack/core/utils/view_model.dart';

class DashboardViewModel extends ViewModel {
  DashboardViewModel(this.loadProfile);
  final Future<Map<String, dynamic>> Function() loadProfile;
  String? name;
  String? role;
  bool loading = true, failed = false;
  Future<void> load() async {
    try {
      final profile = await loadProfile();
      update(() {
        name = profile['full_name'] as String?;
        role = profile['role'] as String?;
        failed = false;
      });
    } catch (_) {
      update(() => failed = true);
    } finally {
      update(() => loading = false);
    }
  }
}
