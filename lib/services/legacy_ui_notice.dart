import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme_style.dart';
import 'library_store.dart';
import 'shelf_store.dart';

/// One-time notice for users who already had local data before the archive UI
/// became the default. New installs and users who already picked a theme are
/// deliberately excluded.
class LegacyUiNotice {
  LegacyUiNotice._();

  static const seenKey = 'ui_upgrade_notice_seen_v1';

  static Future<bool> shouldShow({
    Future<SharedPreferences> Function()? preferences,
    bool? hasLocalData,
    AppThemeStyle? style,
  }) async {
    final prefs = await (preferences ?? SharedPreferences.getInstance)();
    if (prefs.getBool(seenKey) == true) return false;
    // A saved theme means this user already made a choice in the new UI, or
    // already saw the notice and changed it before the notice was marked.
    if (prefs.containsKey(AppThemeStyleStore.storageKey)) return false;
    bool data;
    if (hasLocalData != null) {
      data = hasLocalData;
    } else {
      try {
        data =
            ShelfStore.instance.records().isNotEmpty ||
            LibraryStore.instance.historySnapshot().isNotEmpty;
      } catch (_) {
        // A store can be unavailable in a failed/partial bootstrap or widget
        // test. Do not mark the notice as seen in that case; retry after the
        // stores are actually ready.
        return false;
      }
    }
    if (!data) {
      // A fresh install is checked before it has any library data. Mark it as
      // skipped now; otherwise the first book added later would make the next
      // launch look like an upgrade and show this notice to a new user.
      await prefs.setBool(seenKey, true);
      return false;
    }
    final current = style ?? AppThemeStyleStore.instance.value;
    return current == AppThemeStyle.archive;
  }

  static Future<void> markSeen({
    Future<SharedPreferences> Function()? preferences,
  }) async {
    try {
      final prefs = await (preferences ?? SharedPreferences.getInstance)();
      await prefs.setBool(seenKey, true);
    } catch (_) {
      // The notice is optional; a failed write may show it one more time.
    }
  }
}
