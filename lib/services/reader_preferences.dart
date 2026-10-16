import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderThemePreset { light, eyeCare, parchment, dark, eink }

enum ReaderTitleAlignment { start, center }

enum ReaderPageMode { paged, scroll }

/// Compact mode keeps one footer; detailed mode also shows book/chapter data.
/// Note: 兼容旧开关的迁移见 .agents/notes/implemented/feature/2026-10-15-reader-info-modes.md
enum ReaderInfoMode { hidden, compact, detailed }

/// Page-turn animation for paged mode, mirroring the official 翻页方式 row:
/// the new page slides in normally (平移), slides over a pinned outgoing page
/// (覆盖), or appears instantly (无). See
/// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
enum ReaderPageTurnStyle { cover, slide, none }

@immutable
class ReaderPreferences {
  static Future<void>? _writes;
  static const _fontSizeKey = 'reader_font_size';
  static const _fontWeightKey = 'reader_font_weight';
  static const _lineHeightKey = 'reader_line_height';
  static const _paragraphSpacingKey = 'reader_paragraph_spacing';
  static const _horizontalPaddingKey = 'reader_horizontal_padding';
  static const _themePresetKey = 'reader_theme_preset';
  static const _letterSpacingKey = 'reader_letter_spacing';
  static const _verticalPaddingKey = 'reader_vertical_padding';
  static const _titleSizeKey = 'reader_title_size';
  static const _titleAlignmentKey = 'reader_title_alignment';
  static const _showReadingInfoKey = 'reader_show_reading_info';
  static const _readingInfoModeKey = 'reader_info_mode';
  static const _followSystemBrightnessKey = 'reader_follow_system_brightness';
  static const _brightnessKey = 'reader_brightness';
  static const _fontPathKey = 'reader_font_path';
  static const _fontNameKey = 'reader_font_name';
  static const _pageModeKey = 'reader_page_mode';
  static const _pageTurnStyleKey = 'reader_page_turn_style';
  static const _volumeKeyTurnKey = 'reader_volume_key_turn';
  static const _keepScreenOnKey = 'reader_keep_screen_on';
  static const _autoTurnSecondsKey = 'reader_auto_turn_seconds';
  static const _listeningFollowKey = 'reader_listening_follow';
  static const _continuousReadingKey = 'reader_continuous_reading';
  static const _einkRefreshIntervalKey = 'reader_eink_refresh_interval';
  static const _instantSwipeTurnKey = 'reader_instant_swipe_turn';
  static const _tapLeftTurnsNextKey = 'reader_tap_left_turns_next';

  final double fontSize;
  final int fontWeight;
  final double lineHeight;
  final double paragraphSpacing;
  final double horizontalPadding;
  final ReaderThemePreset themePreset;
  final double letterSpacing;
  final double verticalPadding;
  final double titleSize;
  final ReaderTitleAlignment titleAlignment;
  final ReaderInfoMode readingInfoMode;
  bool get showReadingInfo => readingInfoMode != ReaderInfoMode.hidden;
  final bool followSystemBrightness;
  final double brightness;
  final String fontPath;
  final String fontName;
  final ReaderPageMode pageMode;
  final ReaderPageTurnStyle pageTurnStyle;
  final bool volumeKeyTurn;
  final bool keepScreenOn;
  final int autoTurnSeconds;

  /// While the audio page narrates this chapter, the reader follows the
  /// playback (听书跟随翻页).
  final bool listeningFollow;

  /// 滚动模式连续阅读：到底继续下拉进入下一章。默认开启。
  /// 普通分页始终直接跨章，不受这个滚动手势开关影响。
  final bool continuousReading;

  /// 墨水屏整屏刷新间隔（页）：翻够这么多页调用一次厂商 EPD 全刷压残影。
  /// 0 表示关闭。默认 10 页，只在设备提供海信 EPD 接口时才会真正触发。
  final int einkRefreshInterval;

  /// 分页模式“滑动直翻”：滑动越过阈值直接翻页，不显示翻页过渡页面与动画。
  /// 适合墨水屏（翻页动画/残影明显）。仅分页模式生效，开启后翻页方式被强制为“无”。
  final bool instantSwipeTurn;

  /// “点击左侧翻右”：开启后点击屏幕左三分之一也翻到下一页（与右侧一致），
  /// 失去“点击左侧返回上一页”。适合单手 / 墨水屏操作。
  final bool tapLeftTurnsNext;

  const ReaderPreferences({
    this.fontSize = 18,
    this.fontWeight = 400,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 12,
    this.horizontalPadding = 20,
    this.themePreset = ReaderThemePreset.light,
    this.letterSpacing = 0,
    this.verticalPadding = 16,
    this.titleSize = 20,
    this.titleAlignment = ReaderTitleAlignment.start,
    bool? showReadingInfo,
    ReaderInfoMode readingInfoMode = ReaderInfoMode.compact,
    this.followSystemBrightness = true,
    this.brightness = 0.5,
    this.fontPath = '',
    this.fontName = '',
    this.pageMode = ReaderPageMode.paged,
    this.pageTurnStyle = ReaderPageTurnStyle.slide,
    this.volumeKeyTurn = false,
    this.keepScreenOn = false,
    this.autoTurnSeconds = 10,
    this.listeningFollow = true,
    this.continuousReading = true,
    this.einkRefreshInterval = 10,
    this.instantSwipeTurn = false,
    this.tapLeftTurnsNext = false,
  }) : readingInfoMode = showReadingInfo == false
           ? ReaderInfoMode.hidden
           : readingInfoMode;

  ReaderPreferences copyWith({
    double? fontSize,
    int? fontWeight,
    double? lineHeight,
    double? paragraphSpacing,
    double? horizontalPadding,
    ReaderThemePreset? themePreset,
    double? letterSpacing,
    double? verticalPadding,
    double? titleSize,
    ReaderTitleAlignment? titleAlignment,
    bool? showReadingInfo,
    ReaderInfoMode? readingInfoMode,
    bool? followSystemBrightness,
    double? brightness,
    String? fontPath,
    String? fontName,
    ReaderPageMode? pageMode,
    ReaderPageTurnStyle? pageTurnStyle,
    bool? volumeKeyTurn,
    bool? keepScreenOn,
    int? autoTurnSeconds,
    bool? listeningFollow,
    bool? continuousReading,
    int? einkRefreshInterval,
    bool? instantSwipeTurn,
    bool? tapLeftTurnsNext,
  }) {
    return ReaderPreferences(
      fontSize: fontSize ?? this.fontSize,
      fontWeight: fontWeight ?? this.fontWeight,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      themePreset: themePreset ?? this.themePreset,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      verticalPadding: verticalPadding ?? this.verticalPadding,
      titleSize: titleSize ?? this.titleSize,
      titleAlignment: titleAlignment ?? this.titleAlignment,
      readingInfoMode:
          readingInfoMode ??
          (showReadingInfo == false
              ? ReaderInfoMode.hidden
              : showReadingInfo == true && !this.showReadingInfo
              ? ReaderInfoMode.compact
              : this.readingInfoMode),
      followSystemBrightness:
          followSystemBrightness ?? this.followSystemBrightness,
      brightness: brightness ?? this.brightness,
      fontPath: fontPath ?? this.fontPath,
      fontName: fontName ?? this.fontName,
      pageMode: pageMode ?? this.pageMode,
      pageTurnStyle: pageTurnStyle ?? this.pageTurnStyle,
      volumeKeyTurn: volumeKeyTurn ?? this.volumeKeyTurn,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      autoTurnSeconds: autoTurnSeconds ?? this.autoTurnSeconds,
      listeningFollow: listeningFollow ?? this.listeningFollow,
      continuousReading: continuousReading ?? this.continuousReading,
      einkRefreshInterval:
          einkRefreshInterval ?? this.einkRefreshInterval,
      instantSwipeTurn: instantSwipeTurn ?? this.instantSwipeTurn,
      tapLeftTurnsNext: tapLeftTurnsNext ?? this.tapLeftTurnsNext,
    ).normalized();
  }

  ReaderPreferences normalized() {
    final normalizedWeight = ((fontWeight.clamp(300, 700) / 100).round() * 100)
        .clamp(300, 700);
    return ReaderPreferences(
      fontSize: fontSize.isFinite ? fontSize.clamp(14, 32) : 18,
      fontWeight: normalizedWeight,
      lineHeight: lineHeight.isFinite ? lineHeight.clamp(1.2, 2.4) : 1.8,
      paragraphSpacing: paragraphSpacing.isFinite
          ? paragraphSpacing.clamp(0, 32)
          : 12,
      horizontalPadding: horizontalPadding.isFinite
          ? horizontalPadding.clamp(8, 48)
          : 20,
      themePreset: themePreset,
      letterSpacing: letterSpacing.isFinite ? letterSpacing.clamp(-0.5, 3) : 0,
      verticalPadding: verticalPadding.isFinite
          ? verticalPadding.clamp(0, 64)
          : 16,
      titleSize: titleSize.isFinite ? titleSize.clamp(16, 40) : 20,
      titleAlignment: titleAlignment,
      readingInfoMode: readingInfoMode,
      followSystemBrightness: followSystemBrightness,
      brightness: brightness.isFinite ? brightness.clamp(0.02, 1) : 0.5,
      fontPath: fontPath,
      fontName: fontPath.isEmpty ? '' : fontName,
      pageMode: pageMode,
      pageTurnStyle: pageTurnStyle,
      volumeKeyTurn: volumeKeyTurn,
      keepScreenOn: keepScreenOn,
      autoTurnSeconds: autoTurnSeconds.isFinite
          ? autoTurnSeconds.round().clamp(3, 60)
          : 10,
      listeningFollow: listeningFollow,
      continuousReading: continuousReading,
      einkRefreshInterval: einkRefreshInterval.clamp(0, 100),
      instantSwipeTurn: instantSwipeTurn,
      tapLeftTurnsNext: tapLeftTurnsNext,
    );
  }

  static Future<ReaderPreferences> load() async {
    await _writes;
    final preferences = await SharedPreferences.getInstance();
    final rawPreset = preferences.get(_themePresetKey);
    final preset = ReaderThemePreset.values.firstWhere(
      (value) => value.name == rawPreset,
      orElse: () => ReaderThemePreset.light,
    );
    return ReaderPreferences(
      fontSize: _number(preferences, _fontSizeKey) ?? 18,
      fontWeight: (_number(preferences, _fontWeightKey) ?? 400).round(),
      lineHeight: _number(preferences, _lineHeightKey) ?? 1.8,
      paragraphSpacing: _number(preferences, _paragraphSpacingKey) ?? 12,
      horizontalPadding: _number(preferences, _horizontalPaddingKey) ?? 20,
      themePreset: preset,
      letterSpacing: _number(preferences, _letterSpacingKey) ?? 0,
      verticalPadding: _number(preferences, _verticalPaddingKey) ?? 16,
      titleSize:
          _number(preferences, _titleSizeKey) ??
          ((_number(preferences, _fontSizeKey) ?? 18) + 2),
      titleAlignment: ReaderTitleAlignment.values.firstWhere(
        (value) => value.name == preferences.get(_titleAlignmentKey),
        orElse: () => ReaderTitleAlignment.start,
      ),
      readingInfoMode: ReaderInfoMode.values.firstWhere(
        (mode) => mode.name == preferences.get(_readingInfoModeKey),
        orElse: () => _boolean(preferences, _showReadingInfoKey) == false
            ? ReaderInfoMode.hidden
            : ReaderInfoMode.compact,
      ),
      followSystemBrightness:
          _boolean(preferences, _followSystemBrightnessKey) ?? true,
      brightness: _number(preferences, _brightnessKey) ?? 0.5,
      fontPath: _string(preferences, _fontPathKey),
      fontName: _string(preferences, _fontNameKey),
      pageMode: ReaderPageMode.values.firstWhere(
        (value) => value.name == preferences.get(_pageModeKey),
        orElse: () => ReaderPageMode.paged,
      ),
      pageTurnStyle: ReaderPageTurnStyle.values.firstWhere(
        (value) => value.name == preferences.get(_pageTurnStyleKey),
        orElse: () => ReaderPageTurnStyle.slide,
      ),
      volumeKeyTurn: _boolean(preferences, _volumeKeyTurnKey) ?? false,
      keepScreenOn: _boolean(preferences, _keepScreenOnKey) ?? false,
      autoTurnSeconds: (_number(preferences, _autoTurnSecondsKey) ?? 10)
          .round()
          .clamp(3, 60),
      listeningFollow: _boolean(preferences, _listeningFollowKey) ?? true,
      continuousReading: _boolean(preferences, _continuousReadingKey) ?? true,
      einkRefreshInterval:
          (_number(preferences, _einkRefreshIntervalKey) ?? 10).round(),
      instantSwipeTurn: _boolean(preferences, _instantSwipeTurnKey) ?? false,
      tapLeftTurnsNext: _boolean(preferences, _tapLeftTurnsNextKey) ?? false,
    ).normalized();
  }

  Future<void> save() {
    final snapshot = normalized();
    final previous = _writes ?? Future<void>.value();
    final write = previous.then((_) => snapshot._write());
    final settled = write.catchError((Object _) {});
    _writes = settled;
    return write.whenComplete(() {
      if (identical(_writes, settled)) _writes = null;
    });
  }

  Future<void> _write() async {
    final preferences = await SharedPreferences.getInstance();
    final value = normalized();
    await Future.wait<bool>([
      preferences.setDouble(_fontSizeKey, value.fontSize),
      preferences.setInt(_fontWeightKey, value.fontWeight),
      preferences.setDouble(_lineHeightKey, value.lineHeight),
      preferences.setDouble(_paragraphSpacingKey, value.paragraphSpacing),
      preferences.setDouble(_horizontalPaddingKey, value.horizontalPadding),
      preferences.setString(_themePresetKey, value.themePreset.name),
      preferences.setDouble(_letterSpacingKey, value.letterSpacing),
      preferences.setDouble(_verticalPaddingKey, value.verticalPadding),
      preferences.setDouble(_titleSizeKey, value.titleSize),
      preferences.setString(_titleAlignmentKey, value.titleAlignment.name),
      preferences.setBool(_showReadingInfoKey, value.showReadingInfo),
      preferences.setString(_readingInfoModeKey, value.readingInfoMode.name),
      preferences.setBool(
        _followSystemBrightnessKey,
        value.followSystemBrightness,
      ),
      preferences.setDouble(_brightnessKey, value.brightness),
      preferences.setString(_fontPathKey, value.fontPath),
      preferences.setString(_fontNameKey, value.fontName),
      preferences.setString(_pageModeKey, value.pageMode.name),
      preferences.setString(_pageTurnStyleKey, value.pageTurnStyle.name),
      preferences.setBool(_volumeKeyTurnKey, value.volumeKeyTurn),
      preferences.setBool(_keepScreenOnKey, value.keepScreenOn),
      preferences.setInt(_autoTurnSecondsKey, value.autoTurnSeconds),
      preferences.setBool(_listeningFollowKey, value.listeningFollow),
      preferences.setBool(_continuousReadingKey, value.continuousReading),
      preferences.setInt(
        _einkRefreshIntervalKey,
        value.einkRefreshInterval,
      ),
      preferences.setBool(_instantSwipeTurnKey, value.instantSwipeTurn),
      preferences.setBool(_tapLeftTurnsNextKey, value.tapLeftTurnsNext),
    ]);
  }

  static double? _number(SharedPreferences preferences, String key) {
    final value = preferences.get(key);
    return value is num && value.isFinite ? value.toDouble() : null;
  }

  static bool? _boolean(SharedPreferences preferences, String key) {
    final value = preferences.get(key);
    return value is bool ? value : null;
  }

  static String _string(SharedPreferences preferences, String key) {
    final value = preferences.get(key);
    return value is String ? value : '';
  }
}
