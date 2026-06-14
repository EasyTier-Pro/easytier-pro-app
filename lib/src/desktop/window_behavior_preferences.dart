import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WindowBehaviorPreferences extends ChangeNotifier {
  WindowBehaviorPreferences(SharedPreferences preferences)
    : _preferences = preferences,
      _minimizeToTray =
          preferences.getBool(_minimizeToTrayKey) ?? defaultMinimizeToTray;

  WindowBehaviorPreferences.memory({bool? minimizeToTray})
    : _preferences = null,
      _minimizeToTray = minimizeToTray ?? defaultMinimizeToTray;

  static const bool defaultMinimizeToTray = false;
  static const String _minimizeToTrayKey = 'window_minimize_to_tray';

  final SharedPreferences? _preferences;
  bool _minimizeToTray;

  bool get minimizeToTray => _minimizeToTray;

  Future<void> setMinimizeToTray(bool value) async {
    if (_minimizeToTray == value) {
      return;
    }

    _minimizeToTray = value;
    notifyListeners();
    await _preferences?.setBool(_minimizeToTrayKey, value);
  }
}
