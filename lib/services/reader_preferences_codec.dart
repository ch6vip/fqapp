part of 'reader_preferences.dart';

double? _number(SharedPreferences preferences, String key) {
  final value = preferences.get(key);
  return value is num && value.isFinite ? value.toDouble() : null;
}

bool? _boolean(SharedPreferences preferences, String key) {
  final value = preferences.get(key);
  return value is bool ? value : null;
}

/// 九宫格加载：无保存值时回落默认；旧单手开关开着且无九宫格时，
/// 迁移为单手九宫格（保持旧用户行为不变）。
List<ReaderTapZoneAction> _tapZones(SharedPreferences preferences) {
  final raw = preferences.getStringList(ReaderPreferences._tapZonesKey);
  if (raw == null) {
    if (_boolean(preferences, ReaderPreferences._tapLeftTurnsNextKey) == true) {
      return List<ReaderTapZoneAction>.of(oneHandReaderTapZones);
    }
    return List<ReaderTapZoneAction>.of(defaultReaderTapZones);
  }
  return normalizeReaderTapZones(raw);
}

String _string(SharedPreferences preferences, String key) {
  final value = preferences.get(key);
  return value is String ? value : '';
}
