import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderThemePreset { light, eyeCare, parchment, dark }

enum ReaderTitleAlignment { start, center }

enum ReaderPageMode { paged, scroll }

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
  final bool showReadingInfo;
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
    this.showReadingInfo = true,
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
  });

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
      showReadingInfo: showReadingInfo ?? this.showReadingInfo,
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
      showReadingInfo: showReadingInfo,
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
      showReadingInfo: _boolean(preferences, _showReadingInfoKey) ?? true,
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
      autoTurnSeconds:
          (_number(preferences, _autoTurnSecondsKey) ?? 10).round().clamp(3, 60),
      listeningFollow: _boolean(preferences, _listeningFollowKey) ?? true,
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
