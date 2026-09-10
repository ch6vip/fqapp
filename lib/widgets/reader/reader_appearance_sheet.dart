import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/reader_device.dart';
import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

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

  void _update(ReaderPreferences value) {
    setState(() => _value = value.normalized());
    widget.onChanged(_value);
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
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _section(
                          preset,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '阅读方式',
                                style: TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  for (final mode in ReaderPageMode.values)
                                    ChoiceChip(
                                      key: ValueKey('reader-mode-${mode.name}'),
                                      label: Text(
                                        mode == ReaderPageMode.paged
                                            ? '左右翻页'
                                            : '上下滚动',
                                      ),
                                      selected: _value.pageMode == mode,
                                      onSelected: (_) => _update(
                                        _value.copyWith(pageMode: mode),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        _themeChoices(preset),
                        const SizedBox(height: 16),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final twoColumns =
                                constraints.maxWidth >= 300 &&
                                MediaQuery.textScalerOf(context).scale(14) <=
                                    20;
                            final width = twoColumns
                                ? (constraints.maxWidth - 10) / 2
                                : constraints.maxWidth;
                            return Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                SizedBox(
                                  width: width,
                                  child: _metric(
                                    '字号',
                                    'reader-font-size',
                                    _value.fontSize,
                                    14,
                                    32,
                                    1,
                                    (value) => _value.copyWith(fontSize: value),
                                  ),
                                ),
                                SizedBox(
                                  width: width,
                                  child: _metric(
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
                                ),
                                SizedBox(
                                  width: width,
                                  child: _metric(
                                    '行距',
                                    'reader-line-height',
                                    _value.lineHeight,
                                    1.2,
                                    2.4,
                                    0.1,
                                    (value) =>
                                        _value.copyWith(lineHeight: value),
                                    decimals: 1,
                                  ),
                                ),
                                SizedBox(
                                  width: width,
                                  child: _metric(
                                    '段距',
                                    'reader-paragraph-spacing',
                                    _value.paragraphSpacing,
                                    0,
                                    32,
                                    1,
                                    (value) => _value.copyWith(
                                      paragraphSpacing: value,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 14),
                        _section(
                          preset,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '字体',
                                style: TextStyle(
                                  color: preset.mutedTextColor,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  ChoiceChip(
                                    label: const Text('系统字体'),
                                    selected: _value.fontPath.isEmpty,
                                    onSelected: (_) => _update(
                                      _value.copyWith(
                                        fontPath: '',
                                        fontName: '',
                                      ),
                                    ),
                                  ),
                                  if (_value.fontPath.isNotEmpty)
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 220,
                                      ),
                                      child: Chip(
                                        avatar: const Icon(
                                          Icons.check_rounded,
                                          size: 16,
                                        ),
                                        label: Text(
                                          _value.fontName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  TextButton.icon(
                                    onPressed: _importing ? null : _importFont,
                                    icon: _importing
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.add_rounded,
                                            size: 18,
                                          ),
                                    label: Text(_importing ? '正在导入' : '导入字体'),
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
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 7,
                                runSpacing: 6,
                                children: [
                                  for (final entry in const {
                                    300: '细',
                                    400: '标准',
                                    500: '适中',
                                    600: '偏粗',
                                    700: '粗',
                                  }.entries)
                                    ChoiceChip(
                                      label: Text(entry.value),
                                      selected: _value.fontWeight == entry.key,
                                      onSelected: (_) => _update(
                                        _value.copyWith(fontWeight: entry.key),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        _section(
                          preset,
                          padding: EdgeInsets.zero,
                          child: ExpansionTile(
                            key: const ValueKey('reader-more-appearance'),
                            title: const Text(
                              '标题与留白',
                              style: TextStyle(fontSize: 14),
                            ),
                            subtitle: Text(
                              '标题大小、对齐、页面边距',
                              style: TextStyle(
                                color: preset.mutedTextColor,
                                fontSize: 12,
                              ),
                            ),
                            shape: const Border(),
                            collapsedShape: const Border(),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              10,
                              0,
                              10,
                              10,
                            ),
                            children: [
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
                              const SizedBox(height: 10),
                              _metric(
                                '左右留白',
                                'reader-horizontal-padding',
                                _value.horizontalPadding,
                                8,
                                48,
                                1,
                                (value) =>
                                    _value.copyWith(horizontalPadding: value),
                              ),
                              const SizedBox(height: 10),
                              _metric(
                                '上下留白',
                                'reader-vertical-padding',
                                _value.verticalPadding,
                                0,
                                64,
                                1,
                                (value) =>
                                    _value.copyWith(verticalPadding: value),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile.adaptive(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          title: const Text(
                            '阅读信息',
                            style: TextStyle(fontSize: 14),
                          ),
                          subtitle: const Text(
                            '书名、章节、进度、时间与电量',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: _value.showReadingInfo,
                          onChanged: (value) =>
                              _update(_value.copyWith(showReadingInfo: value)),
                        ),
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: () => _update(
                            ReaderPreferences(
                              followSystemBrightness:
                                  _value.followSystemBrightness,
                              brightness: _value.brightness,
                            ),
                          ),
                          child: const Text('恢复默认排版'),
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

  Widget _themeChoices(ReaderThemePreset preset) => Row(
    children: [
      for (final choice in ReaderThemePreset.values)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Semantics(
              selected: choice == preset,
              button: true,
              label: '${choice.label}阅读背景',
              child: InkWell(
                key: ValueKey('reader-theme-${choice.name}'),
                onTap: () => _update(_value.copyWith(themePreset: choice)),
                borderRadius: BorderRadius.circular(16),
                child: Ink(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: choice.backgroundColor,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: choice == preset
                          ? preset.accentColor
                          : preset.borderColor,
                      width: choice == preset ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '阅',
                        style: TextStyle(color: choice.textColor, fontSize: 22),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        choice.label,
                        style: TextStyle(color: choice.textColor, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _section(
    ReaderThemePreset preset, {
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(12),
  }) => Material(
    color: preset.fieldColor,
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );

  Widget _metric(
    String label,
    String key,
    double value,
    double min,
    double max,
    double step,
    ReaderPreferences Function(double) update, {
    int decimals = 0,
  }) => _section(
    _value.themePreset,
    padding: const EdgeInsets.fromLTRB(10, 9, 10, 2),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            Text(
              value.toStringAsFixed(decimals),
              style: TextStyle(
                color: _value.themePreset.accentColor,
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
                onChanged: (value) => _update(update(value)),
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
    ),
  );
}
