import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/reader_device.dart';
import '../../services/reader_preferences.dart';
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

  const ReaderAppearanceSheet({
    super.key,
    required this.initialValue,
    required this.onChanged,
    required this.onPickFont,
  });

  @override
  State<ReaderAppearanceSheet> createState() => _ReaderAppearanceSheetState();
}

class _ReaderAppearanceSheetState extends State<ReaderAppearanceSheet> {
  late ReaderPreferences _value = widget.initialValue;
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
    final preset = _value.themePreset;
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        color: preset.sheetColor,
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
                  width: 32,
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
                        icon: const Icon(Icons.close_rounded),
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
                        // 背景: official aki row — 32dp circular swatches,
                        // the selected one wrapped in a 1.3dp accent ring.
                        _row(
                          label: '背景',
                          child: Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                for (final choice
                                    in ReaderThemePreset.values)
                                  _swatch(preset, choice),
                              ],
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
                          '音量键翻页',
                          subtitle: '音量下 = 下一页，音量上 = 上一页',
                          value: _value.volumeKeyTurn,
                          onChanged: (value) => _update(
                            _value.copyWith(volumeKeyTurn: value),
                          ),
                        ),
                        _toggle(
                          '阅读时保持屏幕常亮',
                          value: _value.keepScreenOn,
                          onChanged: (value) => _update(
                            _value.copyWith(keepScreenOn: value),
                          ),
                        ),
                        _toggle(
                          '阅读信息',
                          subtitle: '书名、章节、进度、时间与电量',
                          value: _value.showReadingInfo,
                          onChanged: (value) =>
                              _update(_value.copyWith(showReadingInfo: value)),
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
                                color: _value.themePreset.textColor,
                                fontSize: 13,
                              ),
                            ),
                            subtitle: Text(
                              '字距、标题字号与对齐',
                              style: TextStyle(
                                color: _value.themePreset.mutedTextColor,
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
                        // 恢复默认: official akh row — centred 28dp pill.
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: Center(
                            child: TextButton(
                              style: TextButton.styleFrom(
                                backgroundColor: _value.themePreset.fieldColor,
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
                                  color: _value.themePreset.textColor,
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
    final preset = _value.themePreset;
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
  Widget _swatch(ReaderThemePreset preset, ReaderThemePreset choice) {
    final selected = choice == preset;
    return Semantics(
      selected: selected,
      button: true,
      label: '${choice.label}阅读背景',
      child: InkWell(
        key: ValueKey('reader-theme-${choice.name}'),
        onTap: () => _update(_value.copyWith(themePreset: choice)),
        borderRadius: BorderRadius.circular(19),
        child: Container(
          width: 38,
          height: 38,
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
              style: TextStyle(color: choice.textColor, fontSize: 13),
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
    final preset = _value.themePreset;
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
    final preset = _value.themePreset;
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
    final preset = _value.themePreset;
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
    final preset = _value.themePreset;
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
              icon: const Icon(Icons.remove_rounded, size: 17),
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
              icon: const Icon(Icons.add_rounded, size: 17),
            ),
          ],
        ),
      ],
    );
  }
}
