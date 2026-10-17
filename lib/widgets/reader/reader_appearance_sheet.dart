import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_device.dart';
import '../../services/reader_preferences.dart';
import '../../services/reader_tap_zones.dart';
import 'reader_tap_zone_sheet.dart';
import 'reader_theme.dart';

/// The reader typesetting bottom sheet, laid out after the official panel
/// (`res/layout` rows akd/aki/akj/aho + `MultipleOptionsView`): 16dp side
/// margins, ~40dp rows with 12sp-13sp leading labels, 32dp circular background
/// swatches with a selected ring, evenly divided option chips (≥55dp), and a
/// centred 28dp pill for 恢复默认. Row order and data plumbing are ours; the
/// geometry and visual language are the official panel's.
class ReaderAppearanceSheet extends StatefulWidget {
  final ReaderPreferences initialValue;
  final ValueChanged<ReaderPreferences> onChanged;
  final Future<ReaderFont?> Function() onPickFont;

  /// 全局墨水屏模式已开启时，阅读背景跟随全局，不由本面板的色块决定。
  /// 此时面板显示墨水屏为选中，色块点按禁用，避免点 夜间/米白 却毫无变化。
  final bool einkOverride;

  const ReaderAppearanceSheet({
    super.key,
    required this.initialValue,
    required this.onChanged,
    required this.onPickFont,
    this.einkOverride = false,
  });

  @override
  State<ReaderAppearanceSheet> createState() => _ReaderAppearanceSheetState();
}

class _ReaderAppearanceSheetState extends State<ReaderAppearanceSheet> {
  late ReaderPreferences _value = widget.initialValue;

  /// 面板显示用的预设：全局墨水屏开启时强制墨水屏，与保存的预设分开，
  /// 其它排版改动仍写保存的预设，关闭全局模式后恢复。
  ReaderThemePreset get _displayPreset =>
      widget.einkOverride ? ReaderThemePreset.eink : _value.themePreset;
  bool _importing = false;
  String? _fontError;

  /// Applies the pending value to the reader page. The reader re-measures the
  /// whole chapter synchronously on the UI isolate, so a slider firing
  /// `onChanged` per tick used to re-typeset the chapter ten-plus times per
  /// drag and dropped frames all the way down. The sheet keeps its own thumb
  /// and label instant, coalesces the page updates (120ms trailing), and
  /// flushes the final value on release/dispose so nothing is lost.
  Timer? _notifyDebounce;
  bool _notifyPending = false;

  void _update(ReaderPreferences value) {
    setState(() => _value = value.normalized());
    _notifyPending = true;
    _notifyDebounce?.cancel();
    _notifyDebounce = Timer(const Duration(milliseconds: 120), _notifyParent);
  }

  void _notifyParent() {
    _notifyDebounce = null;
    if (!mounted || !_notifyPending) return;
    _notifyPending = false;
    widget.onChanged(_value);
  }

  void _flushNotify() {
    _notifyDebounce?.cancel();
    _notifyDebounce = null;
    if (!mounted || !_notifyPending) return;
    _notifyPending = false;
    widget.onChanged(_value);
  }

  @override
  void dispose() {
    // The sheet may close mid-drag; the last value must still reach the
    // reader page or the saved preference would trail the visible one.
    _flushNotify();
    super.dispose();
  }

  /// 点击区域行摘要：左列 / 中列 / 右列的动作（每列三格相同是常见配置，
  /// 不同时只展示“已自定义”）。
  String get _tapZonesSummary {
    final zones = _value.tapZones;
    String columnSummary(int column) {
      final actions = <ReaderTapZoneAction>{
        zones[column],
        zones[3 + column],
        zones[6 + column],
      };
      if (actions.length == 1) return actions.single.label;
      return '已自定义';
    }

    return '左 ${columnSummary(0)} · 中 ${columnSummary(1)} · 右 ${columnSummary(2)}';
  }

  Future<void> _editTapZones() async {
    final zones = await showReaderTapZoneEditor(
      context: context,
      initialZones: _value.tapZones,
    );
    if (zones != null && mounted) {
      _update(_value.copyWith(tapZones: zones));
    }
  }

  Future<void> _importFont() async {
    setState(() {
      _importing = true;
      _fontError = null;
    });
    try {
      final font = await widget.onPickFont();
      if (!mounted || font == null) return;
      _update(_value.copyWith(fontPath: font.path, fontName: font.name));
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _fontError = error is PlatformException
            ? error.message ?? '字体导入失败，请重新选择'
            : '无法载入字体，请选择有效的 TTF、OTF 或 TTC 文件',
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preset = _displayPreset;
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: AnimatedContainer(
        // 墨水屏：任何插值动画都会在屏上留残影，排版面板直接跳变。
        duration: preset.isEink
            ? Duration.zero
            : const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: preset.sheetColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          border: Border(
            top: BorderSide(
              color: preset.isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
              width: 0.8,
            ),
          ),
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: EdgeInsets.only(
              bottom:
                  MediaQuery.viewInsetsOf(context).bottom +
                  MediaQuery.paddingOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 4),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: preset.mutedTextColor.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '排版设置',
                          style: TextStyle(
                            color: preset.textColor,
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭排版设置',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(LucideIcons.x, size: 20),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('reader-appearance-scroll'),
                    padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 全局墨水屏开启时背景跟随全局，色块仅作展示。
                        if (widget.einkOverride)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              16,
                              0,
                              16,
                              12,
                            ),
                            child: Text(
                              '全局墨水屏模式已开启，背景跟随全局设置',
                              style: TextStyle(
                                color: preset.mutedTextColor,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        // 背景: official aki row — 32dp circular swatches,
                        // the selected one wrapped in a 1.3dp accent ring.
                        // 5 个预设时固定 38dp 在窄屏 (280dp, 2.0 字号) 下溢出
                        // 18px (5×38=190 > 可用 172)，见 CI run 38597871819。
                        // 直径随可用宽度自适应，正常宽度仍为 38dp。
                        _row(
                          label: '背景',
                          child: Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final count =
                                    ReaderThemePreset.values.length;
                                final diameter =
                                    (constraints.maxWidth / count - 4)
                                        .clamp(24.0, 38.0);
                                return Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: [
                                    for (final choice
                                        in ReaderThemePreset.values)
                                      _swatch(preset, choice, diameter),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                        // 字号: official akd row — A− / A+ pill areas with
                        // the current size between them.
                        _row(
                          label: '字号',
                          child: Expanded(
                            child: _stepper(
                              key: const ValueKey('reader-font-size'),
                              value: _value.fontSize,
                              min: 14,
                              max: 32,
                              format: (value) => value.round().toString(),
                              onStep: (value) => _update(
                                _value.copyWith(fontSize: value),
                              ),
                            ),
                          ),
                        ),
                        // 行距 / 段距 / 边距: official akj/aho rows — label +
                        // evenly divided option chips (≥55dp each).
                        _optionsRow(
                          '行距',
                          _chips<double>(
                            key: 'reader-line-height',
                            options: {1.5: '紧凑', 1.8: '标准', 2.1: '宽松'},
                            selected: _value.lineHeight,
                            format: (value) => value.toStringAsFixed(1),
                            onSelected: (value) =>
                                _update(_value.copyWith(lineHeight: value)),
                          ),
                        ),
                        _optionsRow(
                          '段距',
                          _chips<int>(
                            key: 'reader-paragraph-spacing',
                            options: const {6: '紧凑', 12: '标准', 20: '宽松'},
                            selected: _value.paragraphSpacing.round(),
                            format: (value) => '$value',
                            onSelected: (value) => _update(
                              _value.copyWith(paragraphSpacing: value.toDouble()),
                            ),
                          ),
                        ),
                        _optionsRow(
                          '左右边距',
                          _chips<double>(
                            key: 'reader-horizontal-padding',
                            options: {12.0: '窄', 20.0: '标准', 32.0: '宽'},
                            selected: _value.horizontalPadding,
                            format: (value) => '$value',
                            onSelected: (value) => _update(
                              _value.copyWith(horizontalPadding: value),
                            ),
                          ),
                        ),
                        _optionsRow(
                          '上下边距',
                          _chips<double>(
                            key: 'reader-vertical-padding',
                            options: {8.0: '窄', 16.0: '标准', 28.0: '宽'},
                            selected: _value.verticalPadding,
                            format: (value) => '$value',
                            onSelected: (value) => _update(
                              _value.copyWith(verticalPadding: value),
                            ),
                          ),
                        ),
                        // 阅读方式 + 翻页方式: two official option rows.
                        _row(
                          label: '阅读方式',
                          child: Expanded(
                            child: Row(
                              children: [
                                for (final mode in ReaderPageMode.values)
                                  Expanded(
                                    child: _chip(
                                      key: ValueKey(
                                        'reader-mode-${mode.name}',
                                      ),
                                      label: mode == ReaderPageMode.paged
                                          ? '左右翻页'
                                          : '上下滚动',
                                      selected: _value.pageMode == mode,
                                      onTap: () => _update(
                                        _value.copyWith(pageMode: mode),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        _row(
                          label: '翻页方式',
                          child: Expanded(
                            child: Row(
                              children: [
                                for (final style in ReaderPageTurnStyle.values)
                                  Expanded(
                                    child: _chip(
                                      label: switch (style) {
                                        ReaderPageTurnStyle.cover => '覆盖',
                                        ReaderPageTurnStyle.slide => '平移',
                                        ReaderPageTurnStyle.curl => '仿真',
                                        ReaderPageTurnStyle.none => '无',
                                      },
                                      selected: _value.pageTurnStyle == style,
                                      onTap: () => _update(
                                        _value.copyWith(pageTurnStyle: style),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        _toggle(
                          '滑动直翻（无过渡动画）',
                          subtitle:
                              '分页模式：滑动越过阈值直接翻页，不显示翻页过渡与动画；开启后翻页方式强制为“无”。适合墨水屏',
                          value: _value.instantSwipeTurn,
                          onChanged: (value) => _update(
                            _value.copyWith(instantSwipeTurn: value),
                          ),
                        ),
                        _row(
                          label: '点击区域',
                          child: Expanded(
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _tapZonesSummary,
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed: _editTapZones,
                                  child: const Text('设置'),
                                ),
                              ],
                            ),
                          ),
                        ),
                        _row(
                          label: '自动翻页',
                          child: Expanded(
                            child: Row(
                              children: [
                                for (final seconds in const [3, 5, 10, 20, 30])
                                  Expanded(
                                    child: _chip(
                                      label: '$seconds秒',
                                      selected:
                                          _value.autoTurnSeconds == seconds,
                                      onTap: () => _update(
                                        _value.copyWith(
                                          autoTurnSeconds: seconds,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        // 字体: import + weight chips, official 字体 row shape.
                        _row(
                          label: '字体',
                          child: Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: _chip(
                                        label: '系统字体',
                                        selected: _value.fontPath.isEmpty,
                                        onTap: () => _update(
                                          _value.copyWith(
                                            fontPath: '',
                                            fontName: '',
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Expanded(
                                      child: _chip(
                                        label: _value.fontPath.isEmpty
                                            ? '导入字体'
                                            : _value.fontName,
                                        selected: _value.fontPath.isNotEmpty,
                                        onTap: _importing ? null : _importFont,
                                      ),
                                    ),
                                  ],
                                ),
                                if (_fontError != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      _fontError!,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        _row(
                          label: '字重',
                          child: Expanded(
                            child: Row(
                              children: [
                                for (final entry in const {
                                  300: '细',
                                  400: '标准',
                                  500: '适中',
                                  600: '偏粗',
                                  700: '粗',
                                }.entries)
                                  Expanded(
                                    child: _chip(
                                      label: entry.value,
                                      selected:
                                          _value.fontWeight == entry.key,
                                      onTap: () => _update(
                                        _value.copyWith(
                                          fontWeight: entry.key,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        // Toggles: official switch rows — label left,
                        // switch right, ~40dp row.
                        _toggle(
                          '听书跟随翻页',
                          subtitle: '听书页播放本章时，阅读器按播放进度自动翻页',
                          value: _value.listeningFollow,
                          onChanged: (value) => _update(
                            _value.copyWith(listeningFollow: value),
                          ),
                        ),
                        _toggle(
                          '朗读句高亮',
                          subtitle: '朗读时给正在读的句子加背景色，与跟随翻页独立',
                          value: _value.narrationHighlight,
                          onChanged: (value) => _update(
                            _value.copyWith(narrationHighlight: value),
                          ),
                        ),
                        _toggle(
                          '音量键翻页',
                          subtitle: '音量下 = 下一页，音量上 = 上一页',
                          value: _value.volumeKeyTurn,
                          onChanged: (value) => _update(
                            _value.copyWith(volumeKeyTurn: value),
                          ),
                        ),
                        _toggle(
                          '连续阅读',
                          subtitle: '滚动到底继续下拉进入下一章；分页始终直接跨章',
                          value: _value.continuousReading,
                          onChanged: (value) => _update(
                            _value.copyWith(continuousReading: value),
                          ),
                        ),
                        _toggle(
                          '段评气泡',
                          subtitle: '段落末尾显示评论数气泡；关闭后仍可从段落菜单和章节末尾打开段评',
                          value: _value.showParagraphBubbles,
                          onChanged: (value) => _update(
                            _value.copyWith(showParagraphBubbles: value),
                          ),
                        ),
                        _toggle(
                          '阅读时保持屏幕常亮',
                          value: _value.keepScreenOn,
                          onChanged: (value) =>
                              _update(_value.copyWith(keepScreenOn: value)),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '阅读信息',
                                style: TextStyle(
                                  color: _displayPreset.textColor,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  for (final mode in ReaderInfoMode.values)
                                    ChoiceChip(
                                      key: ValueKey('reader-info-${mode.name}'),
                                      label: Text(switch (mode) {
                                        ReaderInfoMode.hidden => '关闭',
                                        ReaderInfoMode.compact => '简洁',
                                        ReaderInfoMode.detailed => '详细',
                                      }),
                                      selected: _value.readingInfoMode == mode,
                                      onSelected: (_) => _update(
                                        _value.copyWith(readingInfoMode: mode),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                switch (_value.readingInfoMode) {
                                  ReaderInfoMode.hidden => '隐藏顶部与底部阅读信息',
                                  ReaderInfoMode.compact => '仅在底部显示时间与全书进度',
                                  ReaderInfoMode.detailed =>
                                    '显示书名、章节、页码、进度、时间与电量',
                                },
                                style: TextStyle(
                                  color: _displayPreset.mutedTextColor,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 更多排版: fine-grained sliders without an official
                        // counterpart (字距/标题字号/标题对齐), tucked away so the
                        // first screen stays official.
                        Theme(
                          data: Theme.of(context).copyWith(
                            dividerColor: Colors.transparent,
                          ),
                          child: ExpansionTile(
                            key: const ValueKey('reader-more-appearance'),
                            tilePadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                            title: Text(
                              '更多排版',
                              style: TextStyle(
                                color: _displayPreset.textColor,
                                fontSize: 13,
                              ),
                            ),
                            subtitle: Text(
                              '字距、标题字号与对齐',
                              style: TextStyle(
                                color: _displayPreset.mutedTextColor,
                                fontSize: 12,
                              ),
                            ),
                            shape: const Border(),
                            collapsedShape: const Border(),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              16,
                              0,
                              16,
                              8,
                            ),
                            children: [
                              _metric(
                                '字距',
                                'reader-letter-spacing',
                                _value.letterSpacing,
                                -0.5,
                                3,
                                0.1,
                                (value) =>
                                    _value.copyWith(letterSpacing: value),
                                decimals: 1,
                              ),
                              const SizedBox(height: 6),
                              _metric(
                                '标题字号',
                                'reader-title-size',
                                _value.titleSize,
                                16,
                                40,
                                1,
                                (value) => _value.copyWith(titleSize: value),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                children: [
                                  for (final alignment
                                      in ReaderTitleAlignment.values)
                                    ChoiceChip(
                                      label: Text(
                                        alignment == ReaderTitleAlignment.start
                                            ? '标题居左'
                                            : '标题居中',
                                      ),
                                      selected:
                                          _value.titleAlignment == alignment,
                                      onSelected: (_) => _update(
                                        _value.copyWith(
                                          titleAlignment: alignment,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        // 墨水屏模式下才显示整屏刷新间隔：每翻 N 页全刷压残影。
                        if (widget.einkOverride) _einkRefreshIntervalRow(),
                        // 恢复默认: official akh row — centred 28dp pill.
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: Center(
                            child: TextButton(
                              style: TextButton.styleFrom(
                                backgroundColor: _displayPreset.fieldColor,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                minimumSize: const Size(0, 28),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                              ),
                              onPressed: () => _update(
                                ReaderPreferences(
                                  followSystemBrightness:
                                      _value.followSystemBrightness,
                                  brightness: _value.brightness,
                                ),
                              ),
                              child: Text(
                                '恢复默认排版',
                                style: TextStyle(
                                  color: _displayPreset.textColor,
                                  fontSize: 12,
                                  height: 1.0,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One official row: 16dp side margins, ~40dp tall, 12dp below, 13sp label
  /// leading with a 16dp gap, controls filling the rest.
  Widget _row({
    required String label,
    required Widget child,
    double minHeight = 40,
  }) {
    final preset = _displayPreset;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      constraints: BoxConstraints(minHeight: minHeight),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(color: preset.textColor, fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          child,
        ],
      ),
    );
  }

  Widget _optionsRow(String label, Widget chips) =>
      _row(label: label, child: Expanded(child: chips));

  /// 官方 aki 背景 swatch: a 32dp circle in the theme's own background colour,
  /// the selected one wrapped in a 1.3dp accent ring (aqx selector).
  Widget _swatch(
    ReaderThemePreset preset,
    ReaderThemePreset choice,
    double diameter,
  ) {
    final selected = choice == preset;
    return Semantics(
      selected: selected,
      button: true,
      label: '${choice.label}阅读背景',
      child: InkWell(
        key: ValueKey('reader-theme-${choice.name}'),
        onTap: widget.einkOverride
            ? null
            : () => _update(_value.copyWith(themePreset: choice)),
        borderRadius: BorderRadius.circular(diameter / 2),
        child: Container(
          width: diameter,
          height: diameter,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? preset.accentColor
                  : Colors.transparent,
              width: 1.3,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: choice.backgroundColor,
              border: Border.all(color: preset.borderColor, width: 0.5),
            ),
            alignment: Alignment.center,
            child: Text(
              '阅',
              style: TextStyle(
                color: choice.textColor,
                fontSize: diameter * 13 / 38,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 字号 stepper (official akd): two pill areas with the live size between.
  Widget _stepper({
    required Key key,
    required double value,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double> onStep,
  }) {
    final preset = _displayPreset;
    Widget end(String glyph, double size, double delta, String tooltip) =>
        Expanded(
          child: Tooltip(
            message: tooltip,
            child: InkWell(
              borderRadius: BorderRadius.circular(90),
              onTap: delta < 0
                  ? value > min
                        ? () => onStep((value + delta).clamp(min, max).toDouble())
                        : null
                  : value < max
                  ? () => onStep((value + delta).clamp(min, max).toDouble())
                  : null,
              child: Container(
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: preset.fieldColor,
                  borderRadius: BorderRadius.circular(90),
                ),
                child: Text(
                  glyph,
                  style: TextStyle(
                    color: preset.textColor,
                    fontSize: size,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        );
    return SizedBox(
      key: key,
      height: 40,
      child: Row(
        children: [
          end('A', 14, -1, '减小字号'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              format(value),
              style: TextStyle(color: preset.accentColor, fontSize: 13),
            ),
          ),
          end('A', 20, 1, '增大字号'),
        ],
      ),
    );
  }

  /// Evenly divided option chips (official MultipleOptionsView): each ≥55dp,
  /// 32dp tall, the selected one accented.
  Widget _chips<T>({
    required String key,
    required Map<T, String> options,
    required T selected,
    required String Function(T) format,
    required ValueChanged<T> onSelected,
  }) => Row(
    children: [
      for (final entry in options.entries)
        Expanded(
          child: _chip(
            key: ValueKey('$key-${entry.key}'),
            label: entry.value,
            selected: selected == entry.key,
            onTap: () => onSelected(entry.key),
          ),
        ),
    ],
  );

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    Key? key,
  }) {
    final preset = _displayPreset;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: selected
            ? preset.accentColor.withValues(alpha: 0.14)
            : preset.fieldColor,
        borderRadius: BorderRadius.circular(90),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 32,
            alignment: Alignment.center,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? preset.accentColor : preset.mutedTextColor,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Official toggle row: label (with optional subtitle) left, switch right.
  Widget _toggle(
    String label, {
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final preset = _displayPreset;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(color: preset.textColor, fontSize: 13),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      style: TextStyle(
                        color: preset.mutedTextColor,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// Fine-grained slider (no official counterpart — kept under 更多排版).
  Widget _metric(
    String label,
    String key,
    double value,
    double min,
    double max,
    double step,
    ReaderPreferences Function(double) update, {
    int decimals = 0,
  }) {
    final preset = _displayPreset;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: preset.textColor, fontSize: 13),
              ),
            ),
            Text(
              value.toStringAsFixed(decimals),
              style: TextStyle(
                color: preset.accentColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              tooltip: '减小$label',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 44),
              padding: EdgeInsets.zero,
              onPressed: value > min
                  ? () => _update(update((value - step).clamp(min, max)))
                  : null,
              icon: const Icon(LucideIcons.minus, size: 16),
            ),
            Expanded(
              child: Slider(
                key: ValueKey(key),
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: ((max - min) / step).round(),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                activeColor: preset.accentColor,
                onChanged: (value) => _update(update(value)),
                onChangeEnd: (value) => _flushNotify(),
                semanticFormatterCallback: (value) =>
                    '$label ${value.toStringAsFixed(decimals)}',
              ),
            ),
            IconButton(
              tooltip: '增大$label',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 44),
              padding: EdgeInsets.zero,
              onPressed: value < max
                  ? () => _update(update((value + step).clamp(min, max)))
                  : null,
              icon: const Icon(LucideIcons.plus, size: 16),
            ),
          ],
        ),
      ],
    );
  }

  /// 墨水屏整屏刷新间隔行：0 关闭，1-100 表示每翻这么多页全刷一次压残影。
  /// 仅在全局墨水屏模式开启（[widget.einkOverride]）时由 build 渲染。
  Widget _einkRefreshIntervalRow() {
    final preset = _displayPreset;
    final interval = _value.einkRefreshInterval.clamp(0, 100);
    final label = interval == 0 ? '关闭' : '$interval 页';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      constraints: const BoxConstraints(minHeight: 40),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  '整屏刷新',
                  style: TextStyle(color: preset.textColor, fontSize: 13),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '每翻 $label 全刷一次',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: preset.textColor, fontSize: 13),
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  color: preset.accentColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: '减小刷新间隔',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 44),
                padding: EdgeInsets.zero,
                onPressed: interval > 0
                    ? () => _update(
                        _value.copyWith(einkRefreshInterval: interval - 1),
                      )
                    : null,
                icon: const Icon(LucideIcons.minus, size: 16),
              ),
              Expanded(
                child: Slider(
                  key: const ValueKey('einkRefreshInterval'),
                  value: interval.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 100,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  activeColor: preset.accentColor,
                  onChanged: (value) => _update(
                    _value.copyWith(einkRefreshInterval: value.round()),
                  ),
                  onChangeEnd: (_) => _flushNotify(),
                  semanticFormatterCallback: (value) =>
                      '每翻 ${value.round()} 页全刷',
                ),
              ),
              IconButton(
                tooltip: '增大刷新间隔',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 44),
                padding: EdgeInsets.zero,
                onPressed: interval < 100
                    ? () => _update(
                        _value.copyWith(einkRefreshInterval: interval + 1),
                      )
                    : null,
                icon: const Icon(LucideIcons.plus, size: 16),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
