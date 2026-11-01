import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/reader_preferences.dart';
import '../reader_tap_zone_sheet.dart';
import '../reader_theme.dart';
import 'reader_settings_state.dart';
import 'reader_typography_settings.dart';
import 'reader_settings_widgets.dart';

/// Actions that close both settings sheets before opening their destination.
enum ReaderMoreSettingsResult { textReplacement, listeningSource }

/// 打开「更多设置」。
///
/// 单独一层约 75% 高的面板，而不是首屏内翻页：改动行距 / 字距时页面还露在
/// 上方，能直接看到实时预览；高度低于首屏，正文不会被完全盖住。
Future<ReaderMoreSettingsResult?> showReaderMoreSettings({
  required BuildContext context,
  required ReaderPreferences initialValue,
  required ValueChanged<ReaderPreferences> onChanged,
  required bool einkOverride,
  required bool oledOverride,
  required bool backgroundLocked,
  bool showListeningSource = false,
}) {
  return showModalBottomSheet<ReaderMoreSettingsResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => ReaderMoreSettingsSheet(
      initialValue: initialValue,
      onChanged: onChanged,
      einkOverride: einkOverride,
      oledOverride: oledOverride,
      backgroundLocked: backgroundLocked,
      showListeningSource: showListeningSource,
    ),
  );
}

class ReaderMoreSettingsSheet extends StatefulWidget {
  const ReaderMoreSettingsSheet({
    super.key,
    required this.initialValue,
    required this.onChanged,
    this.einkOverride = false,
    this.oledOverride = false,
    this.backgroundLocked = false,
    this.showListeningSource = false,
  });

  final ReaderPreferences initialValue;
  final ValueChanged<ReaderPreferences> onChanged;

  /// 全局墨水屏 / OLED 接管背景时，恢复默认不能悄悄改掉保存的预设。
  final bool einkOverride;
  final bool oledOverride;
  final bool backgroundLocked;
  final bool showListeningSource;

  @override
  State<ReaderMoreSettingsSheet> createState() =>
      _ReaderMoreSettingsSheetState();
}

class _ReaderMoreSettingsSheetState
    extends ReaderSettingsState<ReaderMoreSettingsSheet> {
  @override
  ReaderPreferences get initialPreferences => widget.initialValue;

  @override
  ValueChanged<ReaderPreferences> get onPreferencesChanged => widget.onChanged;

  ReaderThemePreset get _displayPreset {
    if (widget.einkOverride) return ReaderThemePreset.eink;
    if (widget.oledOverride) return ReaderThemePreset.dark;
    return value.themePreset;
  }

  void _apply(ReaderPreferences Function(ReaderPreferences) change) =>
      updatePreferences(change(value));

  bool get _noAnimation =>
      value.pageTurnStyle == ReaderPageTurnStyle.none || value.instantSwipeTurn;

  void _setNoAnimation(bool enabled) {
    updatePreferences(
      value.copyWith(
        pageTurnStyle: enabled
            ? ReaderPageTurnStyle.none
            : ReaderPageTurnStyle.slide,
        instantSwipeTurn: enabled,
      ),
    );
  }

  /// 恢复默认排版：保留亮度与跟随系统；背景被全局模式接管时，也保留用户
  /// 已保存的预设，关闭全局模式后仍回到原来那套背景。
  Future<void> _editTapZones() async {
    final zones = await showReaderTapZoneEditor(
      context: context,
      initialZones: value.tapZones,
      preset: _displayPreset,
    );
    if (zones != null && mounted) {
      _apply((current) => current.copyWith(tapZones: zones));
    }
  }

  @override
  Widget build(BuildContext context) {
    final preset = _displayPreset;
    return ReaderSettingsSheetFrame(
      preset: preset,
      title: '更多设置',
      closeTooltip: '关闭更多设置',
      scrollKey: const ValueKey('reader-more-settings-scroll'),
      maxHeightFactor: 0.75,
      children: [
        const ReaderSettingsSectionHeader(title: '排版'),
        ReaderTypographySettings(
          value: value,
          onChanged: updatePreferences,
          backgroundLocked: widget.backgroundLocked,
        ),
        const ReaderSettingsDivider(),
        const ReaderSettingsSectionHeader(title: '操作'),
        ReaderSettingsNavRow(label: '点击区域', onTap: _editTapZones),
        ReaderSettingsSwitchRow(
          label: '音量键翻页',
          value: value.volumeKeyTurn,
          onChanged: (on) =>
              _apply((current) => current.copyWith(volumeKeyTurn: on)),
        ),
        ReaderSettingsSwitchRow(
          label: '连续阅读',
          value: value.continuousReading,
          onChanged: (on) =>
              _apply((current) => current.copyWith(continuousReading: on)),
        ),
        _autoTurnSecondsRow(),
        ReaderSettingsSwitchRow(
          label: '无动画翻页',
          value: _noAnimation,
          onChanged: _setNoAnimation,
        ),
        const ReaderSettingsDivider(),
        const ReaderSettingsSectionHeader(title: '显示'),
        _infoModeRow(),
        ReaderSettingsSwitchRow(
          label: '系统状态栏',
          value: value.showSystemStatusBar,
          onChanged: (on) =>
              _apply((current) => current.copyWith(showSystemStatusBar: on)),
        ),
        ReaderSettingsSwitchRow(
          label: '段评气泡',
          value: value.showParagraphBubbles,
          onChanged: (on) =>
              _apply((current) => current.copyWith(showParagraphBubbles: on)),
        ),
        ReaderSettingsSwitchRow(
          label: '屏幕常亮',
          value: value.keepScreenOn,
          onChanged: (on) =>
              _apply((current) => current.copyWith(keepScreenOn: on)),
        ),
        if (widget.einkOverride || value.themePreset == ReaderThemePreset.eink)
          _einkRefreshRow(),
        const ReaderSettingsDivider(),
        _listeningSection(),
        const ReaderSettingsDivider(),
        ..._videoSettings(),
        const ReaderSettingsDivider(),
        ReaderSettingsNavRow(
          label: '正文替换',
          icon: LucideIcons.replace,
          onTap: () =>
              Navigator.pop(context, ReaderMoreSettingsResult.textReplacement),
        ),
      ],
    );
  }

  List<Widget> _videoSettings() => [
    const ReaderSettingsSectionHeader(title: '改编剧'),
    ReaderSettingsSwitchRow(
      label: '阅读器展示「看」悬浮球',
      value: value.showVideoButton,
      onChanged: (on) =>
          _apply((current) => current.copyWith(showVideoButton: on)),
    ),
    ReaderSettingsSwitchRow(
      label: '按阅读章节播放改编剧',
      value: value.videoChapterSync,
      onChanged: (on) =>
          _apply((current) => current.copyWith(videoChapterSync: on)),
    ),
  ];

  Widget _listeningSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ReaderSettingsSectionHeader(title: '听书'),
      if (widget.showListeningSource)
        ReaderSettingsNavRow(
          label: '听书方式',
          icon: LucideIcons.headphones,
          onTap: () =>
              Navigator.pop(context, ReaderMoreSettingsResult.listeningSource),
        ),
      ReaderSettingsSwitchRow(
        label: '跟随翻页',
        value: value.listeningFollow,
        onChanged: (on) =>
            _apply((current) => current.copyWith(listeningFollow: on)),
      ),
      ReaderSettingsSwitchRow(
        label: '朗读句高亮',
        value: value.narrationHighlight,
        onChanged: (on) =>
            _apply((current) => current.copyWith(narrationHighlight: on)),
      ),
      // 高亮样式：背景色块 / 文字下划线，或「自动」（墨水屏下划线、其余背景）。
      // 高亮色板：第一枚「自动」跟随当前背景派生（背景同色系深一档），
      // 后面是可选的固定色。关掉高亮时不必展示。
      if (value.narrationHighlight) ...[
        ReaderSettingsRow(label: '高亮样式', child: _highlightStylePicker()),
        ReaderSettingsRow(label: '高亮颜色', child: _highlightColorPicker()),
      ],
    ],
  );

  /// 高亮样式选择：null = 自动（墨水屏下划线，其余背景色块）。
  Widget _highlightStylePicker() {
    final preset = ReaderSettingsTheme.of(context);
    final selected = value.narrationHighlightStyle;

    Widget chip(int? style, String label) {
      final active = selected == style;
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: InkWell(
          key: ValueKey('reader-narration-style-${style ?? 'auto'}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => _apply(
            (current) => style == null
                ? current.copyWith(autoNarrationHighlightStyle: true)
                : current.copyWith(narrationHighlightStyle: style),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active
                    ? preset.textColor
                    : preset.textColor.withValues(alpha: 0.25),
                width: active ? 2 : 1,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: preset.textColor,
                fontSize: 13,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    return Wrap(
      children: [
        chip(null, '自动'),
        chip(ReaderPreferences.narrationHighlightStyleWash, '背景'),
        chip(ReaderPreferences.narrationHighlightStyleUnderline, '下划线'),
      ],
    );
  }

  /// 高亮底色选择：null = 自动（跟随背景派生），其余为
  /// [ReaderPreferences.narrationHighlightPresets] 里的固定色。
  Widget _highlightColorPicker() {
    final preset = ReaderSettingsTheme.of(context);
    final selected = value.narrationHighlightColor;

    Widget dot(int? argb) {
      final active = selected == argb;
      final color = argb == null
          ? Color.alphaBlend(
              preset.textColor.withValues(alpha: 0.10),
              preset.panelColor,
            )
          : Color(argb);
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: InkWell(
          key: ValueKey('reader-narration-color-${argb ?? 'auto'}'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => _apply(
            (current) => argb == null
                ? current.copyWith(autoNarrationHighlightColor: true)
                : current.copyWith(narrationHighlightColor: argb),
          ),
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? preset.textColor
                    : preset.textColor.withValues(alpha: 0.25),
                width: active ? 2 : 1,
              ),
            ),
            child: argb == null
                ? Icon(Icons.auto_awesome, size: 13, color: preset.textColor)
                : null,
          ),
        ),
      );
    }

    return Wrap(
      children: [
        dot(null),
        for (final argb in ReaderPreferences.narrationHighlightPresets)
          dot(argb),
      ],
    );
  }

  Widget _autoTurnSecondsRow() => ReaderSettingsRow(
    label: '自动翻页',
    child: ReaderSettingsChipRow(
      children: [
        for (final seconds in const [3, 5, 10, 20, 30])
          ReaderSettingsChip(
            key: ValueKey('reader-auto-turn-$seconds'),
            label: '$seconds秒',
            selected: value.autoTurnSeconds == seconds,
            onTap: () =>
                _apply((current) => current.copyWith(autoTurnSeconds: seconds)),
          ),
      ],
    ),
  );

  Widget _infoModeRow() => ReaderSettingsRow(
    label: '阅读信息',
    child: ReaderSettingsChipRow(
      children: [
        for (final mode in ReaderInfoMode.values)
          ReaderSettingsChip(
            key: ValueKey('reader-info-${mode.name}'),
            label: switch (mode) {
              ReaderInfoMode.hidden => '关闭',
              ReaderInfoMode.compact => '简洁',
              ReaderInfoMode.detailed => '详细',
            },
            selected: value.readingInfoMode == mode,
            onTap: () =>
                _apply((current) => current.copyWith(readingInfoMode: mode)),
          ),
      ],
    ),
  );

  Widget _einkRefreshRow() => ReaderSettingsRow(
    label: '整屏刷新',
    child: ReaderSettingsStepper(
      key: const ValueKey('einkRefreshInterval'),
      value: value.einkRefreshInterval == 0
          ? '关闭'
          : '${value.einkRefreshInterval} 页',
      decreaseTooltip: '减小刷新间隔',
      increaseTooltip: '增大刷新间隔',
      onDecrease: value.einkRefreshInterval > 0
          ? () => _apply(
              (current) => current.copyWith(
                einkRefreshInterval: current.einkRefreshInterval - 1,
              ),
            )
          : null,
      onIncrease: value.einkRefreshInterval < 100
          ? () => _apply(
              (current) => current.copyWith(
                einkRefreshInterval: current.einkRefreshInterval + 1,
              ),
            )
          : null,
    ),
  );
}
