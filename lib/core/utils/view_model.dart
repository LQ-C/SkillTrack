import 'package:flutter/foundation.dart';

/// Avoid notifications from async work after its screen has been disposed.
abstract class ViewModel extends ChangeNotifier {
  bool _active = true;
  bool get isActive => _active;
  void update(VoidCallback change) {
    if (!_active) return;
    change();
    notifyListeners();
  }

  @override
  void dispose() {
    _active = false;
    super.dispose();
  }
}
