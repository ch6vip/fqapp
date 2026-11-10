import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/shelf/shelf_design.dart';

/// The old shelf's three layouts are independent of the archive's four modes.
/// Reading the legacy key is deliberately non-migrating: neither archive nor
/// legacy preferences may be changed by selecting a classic layout.
class ClassicShelfLayout extends ChangeNotifier {
  ClassicShelfLayout({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static final instance = ClassicShelfLayout();
  static const preferenceKey = 'classic_bookshelf_layout';
  static const legacyKey = 'bookshelf_layout';

  final Future<SharedPreferences> Function() _preferences;
  BookshelfLayout _value = BookshelfLayout.grid;
  int _revision = 0;
  Future<void>? _loading;
  Future<void>? _writes;

  BookshelfLayout get value => _value;

  static BookshelfLayout? _parse(Object? value) =>
      value is int && value >= 0 && value < BookshelfLayout.values.length
      ? BookshelfLayout.values[value]
      : null;

  Future<void> load() =>
      _loading ??= _load().whenComplete(() => _loading = null);

  Future<void> _load() async {
    final revision = _revision;
    try {
      // A newly mounted page must not read behind a previous page's last tap.
      await _writes;
      final prefs = await _preferences();
      final saved =
          _parse(prefs.get(preferenceKey)) ??
          _parse(prefs.get(legacyKey)) ??
          BookshelfLayout.grid;
      if (revision != _revision || saved == _value) return;
      _value = saved;
      notifyListeners();
    } catch (_) {
      // Optional presentation preference: keep the current session usable.
    }
  }

  Future<void> setLayout(BookshelfLayout layout) {
    // Even tapping the default during a pending load is an explicit choice.
    _revision++;
    if (_value != layout) {
      _value = layout;
      notifyListeners();
    }
    final previous = _writes;
    final write = () async {
      if (previous != null) await previous;
      final prefs = await _preferences();
      if (!await prefs.setInt(preferenceKey, layout.index)) {
        throw StateError('Could not save classic shelf layout');
      }
    }();
    // Keep later selections writable after a failed operation. The caller
    // still receives the error and can display the existing persistence hint.
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> whenIdle() async => await _writes;

  @visibleForTesting
  void resetForTest() {
    _revision++;
    _value = BookshelfLayout.grid;
    _loading = null;
    _writes = null;
  }
}
