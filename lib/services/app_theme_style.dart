import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Visual presentation is independent from light/dark mode, reader paper and
/// the user's shelf layout. Unknown values preserve the existing archive UI.
enum AppThemeStyle {
  classic,
  archive;

  String get label => switch (this) {
    classic => '经典主题',
    archive => '档案主题',
  };

  String get description => switch (this) {
    classic => '老版界面 · 封面书架 · 阅读统计',
    archive => '纸张底色 · 档案编号 · 留白排版',
  };

  static AppThemeStyle fromStorage(Object? value) => switch (value) {
    'classic' => classic,
    _ => archive,
  };
}

/// Device-local theme selection. Loading cannot overwrite a newer UI choice,
/// and writes are serialized so rapid switching keeps the last choice on disk.
class AppThemeStyleStore extends ValueNotifier<AppThemeStyle> {
  AppThemeStyleStore({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance,
      super(AppThemeStyle.archive);

  static final instance = AppThemeStyleStore();
  static const storageKey = 'app_theme_style';

  final Future<SharedPreferences> Function() _preferences;
  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();
  bool _loaded = false;
  int _revision = 0;

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final revision = _revision;
    try {
      final prefs = await _preferences();
      if (revision == _revision && _revision == 0) {
        value = AppThemeStyle.fromStorage(prefs.get(storageKey));
      }
      _loaded = true;
    } catch (_) {
      // An optional appearance preference must not block the app. Retry on the
      // next load; keep a choice already made in this session.
    } finally {
      _loading = null;
    }
  }

  /// Applies immediately. A false result means this session changed, but the
  /// choice could not be saved; the caller can show a retryable storage notice.
  Future<bool> select(AppThemeStyle style) {
    ++_revision;
    value = style;
    final saved = _writes.then((_) async {
      try {
        final prefs = await _preferences();
        return await prefs.setString(storageKey, style.name);
      } catch (_) {
        return false;
      }
    });
    _writes = saved.then<void>((_) {});
    return saved;
  }
}
