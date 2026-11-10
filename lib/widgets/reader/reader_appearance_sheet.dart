// Wenku8_Flutter ebcd7f1 ReaderTools category navigation and adjustment preview.
// fqapp remains authoritative for preferences, reading engines and device I/O.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_device.dart';
import '../../services/reader_preferences.dart';
import '../wenku/wenku_ui.dart';
import 'reader_theme.dart';
import 'reader_value_slider.dart';
import 'settings/reader_font_picker_sheet.dart';
import 'settings/reader_more_settings_sheet.dart';
import 'settings/reader_settings_categories.dart';
import 'settings/reader_settings_state.dart';
import 'settings/reader_settings_widgets.dart';
import 'settings/reader_turn_settings.dart';
import 'settings/reader_typography_settings.dart';

enum ReaderSettingsSection { all, appearance, operations, listening }

Future<void> showReaderSettingsSheet({
  required BuildContext context,
  required ReaderPreferences initialValue,
  required ValueChanged<ReaderPreferences> onChanged,
  required Future<ReaderFont?> Function() onPickFont,
  required bool deviceAvailable,
  required double? systemBrightness,
  required ValueChanged<double> onBrightness,
  required VoidCallback onBrightnessEnd,
  required VoidCallback onFollowSystem,
  required bool autoTurnActive,
  required VoidCallback? onAutoTurn,
  bool einkOverride = false,
  bool oledOverride = false,
  VoidCallback? onTextReplacement,
  VoidCallback? onListeningSource,
  ReaderSettingsSection initialSection = ReaderSettingsSection.all,
  ValueChanged<bool>? onPreviewChanged,
  VoidCallback? onMarks,
}) {
  final noMotion =
      einkOverride ||
      initialValue.themePreset == ReaderThemePreset.eink ||
      MediaQuery.disableAnimationsOf(context) ||
      PerformanceScope.reduceMotionOf(context) ||
      !PerformanceScope.of(context).motion;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    // Dragging a value must not compete with the route's dismiss gesture.
    enableDrag: false,
    sheetAnimationStyle: noMotion ? AnimationStyle.noAnimation : null,
    builder: (context) => ReaderAppearanceSheet(
      initialValue: initialValue,
      onChanged: onChanged,
      onPickFont: onPickFont,
      deviceAvailable: deviceAvailable,
      systemBrightness: systemBrightness,
      onBrightness: onBrightness,
      onBrightnessEnd: onBrightnessEnd,
      onFollowSystem: onFollowSystem,
      autoTurnActive: autoTurnActive,
      onAutoTurn: onAutoTurn,
      einkOverride: einkOverride,
      oledOverride: oledOverride,
      onTextReplacement: onTextReplacement,
      onListeningSource: onListeningSource,
      initialSection: initialSection,
      onPreviewChanged: onPreviewChanged,
      onMarks: onMarks,
    ),
  );
}

class ReaderAppearanceSheet extends StatefulWidget {
  const ReaderAppearanceSheet({
    super.key,
    required this.initialValue,
    required this.onChanged,
    required this.onPickFont,
    required this.deviceAvailable,
    required this.systemBrightness,
    required this.onBrightness,
    required this.onBrightnessEnd,
    required this.onFollowSystem,
    required this.autoTurnActive,
    required this.onAutoTurn,
    this.einkOverride = false,
    this.oledOverride = false,
    this.onTextReplacement,
    this.onListeningSource,
    this.initialSection = ReaderSettingsSection.all,
    this.onPreviewChanged,
    this.onMarks,
  });

  final ReaderPreferences initialValue;
  final ValueChanged<ReaderPreferences> onChanged;
  final Future<ReaderFont?> Function() onPickFont;
  final bool deviceAvailable;
  final double? systemBrightness;
  final ValueChanged<double> onBrightness;
  final VoidCallback onBrightnessEnd;
  final VoidCallback onFollowSystem;
  final bool autoTurnActive;
  final VoidCallback? onAutoTurn;
  final bool einkOverride;
  final bool oledOverride;
  final VoidCallback? onTextReplacement;
  final VoidCallback? onListeningSource;
  final ReaderSettingsSection initialSection;
  final ValueChanged<bool>? onPreviewChanged;
  final VoidCallback? onMarks;

  @override
  State<ReaderAppearanceSheet> createState() => _ReaderAppearanceSheetState();
}

class _ReaderAppearanceSheetState
    extends ReaderSettingsState<ReaderAppearanceSheet>
    with SingleTickerProviderStateMixin {
  @override
  ReaderPreferences get initialPreferences => widget.initialValue;
  @override
  ValueChanged<ReaderPreferences> get onPreferencesChanged => widget.onChanged;

  late final AnimationController _expand = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1,
  );
  final _bodyKey = GlobalKey();
  final _contentsKey = GlobalKey();
  final _behaviorKey =
      GlobalKey<ReaderSettingsState<ReaderMoreSettingsSheet>>();
  String? _category;
  Rect? _categoryOrigin;
  Key? _activeAdjustment;
  bool _closing = false;
  bool _brightnessPending = false;

  @override
  void initState() {
    super.initState();
    _category = switch (widget.initialSection) {
      ReaderSettingsSection.operations => 'operations',
      ReaderSettingsSection.listening => 'listening',
      _ => null,
    };
  }

  ReaderThemePreset get _displayPreset => widget.einkOverride
      ? ReaderThemePreset.eink
      : widget.oledOverride
      ? ReaderThemePreset.dark
      : value.themePreset;
  bool get _backgroundLocked => widget.einkOverride || widget.oledOverride;
  bool get _reduceMotion =>
      _displayPreset.isEink ||
      MediaQuery.disableAnimationsOf(context) ||
      PerformanceScope.reduceMotionOf(context) ||
      !PerformanceScope.of(context).motion;

  /// 分类内容总能退回分类网格：坞上只有「外观」「操作」两个入口，面板会
  /// 直达某个分类，网格里的其余分类（听书、书签等）也得走得到。
  bool get _nested => _category != null;
  bool get _alive => mounted && !_closing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) _expand.value = 1;
  }

  void _apply(ReaderPreferences next) {
    if (!_alive) return;
    commitPreferences(next);
    if (_displayPreset.isEink) _expand.value = 1;
  }

  void _flushAll() {
    _behaviorKey.currentState?.flushPreferences();
    flushPreferences();
    if (_brightnessPending) {
      _brightnessPending = false;
      widget.onBrightnessEnd();
    }
  }

  void _preview(Key key, bool active) {
    if (!_alive || (!active && _activeAdjustment != key)) return;
    setState(() => _activeAdjustment = active ? key : null);
    widget.onPreviewChanged?.call(active);
  }

  void _endPreview() {
    if (_activeAdjustment == null) return;
    _activeAdjustment = null;
    widget.onPreviewChanged?.call(false);
  }

  void _close([VoidCallback? action]) {
    if (!_alive) return;
    _flushAll();
    _endPreview();
    _closing = true;
    Navigator.pop(context);
    action?.call();
  }

  void _returnCategories() {
    if (!_alive) return;
    _flushAll();
    _expand.stop();
    _endPreview();
    setState(() => _category = null);
  }

  void _openCategory(String category, Rect? origin) {
    if (!_alive) return;
    if (category == 'bookmarks') {
      _close(widget.onMarks);
      return;
    }
    _flushAll();
    _endPreview();
    setState(() {
      _categoryOrigin = origin;
      _category = category;
    });
    if (_reduceMotion) {
      _expand.value = 1;
    } else {
      _expand.forward(from: 0);
    }
  }

  Future<void> _openFontPicker() async {
    _flushAll();
    final selection = await showReaderFontPicker(
      context: context,
      preset: _displayPreset,
      currentPath: value.fontPath,
      currentName: value.fontName,
      onPickFont: widget.onPickFont,
    );
    if (!_alive || selection == null) return;
    _apply(value.copyWith(fontPath: selection.path, fontName: selection.name));
  }

  @override
  void dispose() {
    _flushAll();
    _closing = true;
    if (_activeAdjustment != null) {
      final preview = widget.onPreviewChanged;
      scheduleMicrotask(() => preview?.call(false));
    }
    _expand.dispose();
    super.dispose();
  }

  Widget _adjustment(Widget child, [Key? key]) {
    final active = _activeAdjustment != null;
    final visible = !active || key == _activeAdjustment;
    return Visibility(
      visible: visible,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: CustomPaint(
        painter: ReaderAdjustmentPlate(
          active && visible
              ? _displayPreset.sheetColor.withValues(alpha: .98)
              : Colors.transparent,
        ),
        child: child,
      ),
    );
  }

  Widget _slider({
    required String id,
    required String label,
    required double current,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ReaderPreferences Function(ReaderPreferences, double) apply,
  }) {
    final key = ValueKey(id);
    final category = _category;
    void update(double next, {bool finish = false}) {
      if (!_alive || category != _category) return;
      _apply(apply(value, next));
      if (finish) flushPreferences();
    }

    return _adjustment(
      ReaderValueSlider(
        sliderKey: key,
        label: label,
        value: current,
        min: min,
        max: max,
        divisions: divisions,
        format: format,
        preset: _displayPreset,
        onPreview: update,
        onCommitted: (next) => update(next, finish: true),
        onInteractionChanged: (active) => _preview(key, active),
      ),
      key,
    );
  }

  List<ReaderSettingsCategory> get _categories => [
    ReaderSettingsCategory(
      'font',
      '字体',
      CupertinoIcons.textformat,
      '${value.fontSize.round()} pt · ${value.fontWeight} 字重',
    ),
    ReaderSettingsCategory(
      'paragraph',
      '段落',
      CupertinoIcons.text_alignleft,
      '${value.lineHeight.toStringAsFixed(1)} 倍行距',
    ),
    const ReaderSettingsCategory(
      'page',
      '屏幕',
      CupertinoIcons.rectangle,
      '页边距 · 状态栏 · 阅读信息',
    ),
    ReaderSettingsCategory(
      'theme',
      '主题',
      CupertinoIcons.paintbrush,
      _displayPreset.label,
    ),
    // 翻页属于外观层面，坞上只有「外观」「操作」两个入口，所以它必须留在
    // 外观网格里，否则翻页动画与自动翻页没有入口。
    ReaderSettingsCategory(
      'turn',
      '翻页',
      CupertinoIcons.arrow_left_right,
      value.pageMode == ReaderPageMode.scroll ? '滚动 · 跨章设置' : '翻页动画 · 自动翻页',
    ),
    if (widget.initialSection != ReaderSettingsSection.appearance) ...[
      const ReaderSettingsCategory(
        'listening',
        '听书',
        CupertinoIcons.headphones,
        '跟随翻页 · 朗读高亮',
      ),
      const ReaderSettingsCategory(
        'operations',
        '操作',
        CupertinoIcons.hand_draw,
        '点击区域 · 音量键 · 正文替换',
      ),
      if (widget.onMarks != null)
        const ReaderSettingsCategory(
          'bookmarks',
          '书签',
          CupertinoIcons.bookmark,
          '保存阅读位置与摘录',
        ),
    ],
  ];

  String get _title => _category == null
      ? widget.initialSection == ReaderSettingsSection.appearance
            ? '外观'
            : '阅读设置'
      : _categories.where((item) => item.id == _category).firstOrNull?.title ??
            '阅读设置';

  Widget _typography(ReaderTypographyCategory category) =>
      ReaderTypographySettings(
        value: value,
        onChanged: _apply,
        backgroundLocked: _backgroundLocked,
        category: category,
        sliderBuilder: _slider,
        decorate: _adjustment,
      );

  Widget _behavior(ReaderBehaviorCategory category) => _adjustment(
    ReaderMoreSettingsSheet(
      key: _behaviorKey,
      initialValue: value,
      onChanged: _apply,
      einkOverride: widget.einkOverride,
      oledOverride: widget.oledOverride,
      backgroundLocked: _backgroundLocked,
      showListeningSource: widget.onListeningSource != null,
      category: category,
      embedded: true,
      onAction: (action) => _close(switch (action) {
        ReaderMoreSettingsResult.textReplacement => widget.onTextReplacement,
        ReaderMoreSettingsResult.listeningSource => widget.onListeningSource,
      }),
    ),
  );

  List<Widget> _items(BuildContext context) => switch (_category) {
    null => [
      ReaderSettingsCategoryGrid(
        categories: _categories,
        onSelected: _openCategory,
        reduceMotion: _reduceMotion,
      ),
    ],
    'font' => [
      _adjustment(
        ReaderSettingsNavRow(
          key: const ValueKey('reader-font-picker'),
          label: value.fontName.isEmpty ? '字体' : '字体 · ${value.fontName}',
          onTap: _openFontPicker,
        ),
      ),
      _typography(ReaderTypographyCategory.font),
    ],
    'paragraph' => [
      _adjustment(_spacingRow()),
      _typography(ReaderTypographyCategory.paragraph),
    ],
    'page' => [
      _typography(ReaderTypographyCategory.page),
      if (widget.deviceAvailable) ...[
        _brightnessSlider(),
        _adjustment(_followSystem()),
      ],
      _behavior(ReaderBehaviorCategory.page),
    ],
    'theme' => [
      _adjustment(_backgroundChoices()),
      if (_backgroundLocked)
        _adjustment(
          Text(
            widget.einkOverride
                ? '全局墨水屏模式已开启，背景跟随全局设置'
                : '全局 OLED 纯黑已开启，背景跟随全局设置',
            style: TextStyle(
              color: _displayPreset.mutedTextColor,
              fontSize: 12,
            ),
          ),
        ),
      _behavior(ReaderBehaviorCategory.theme),
    ],
    'turn' => [
      _adjustment(ReaderTurnSettings(value: value, onChanged: _apply)),
      _autoTurn(),
      _behavior(ReaderBehaviorCategory.turn),
    ],
    'listening' => [_behavior(ReaderBehaviorCategory.listening)],
    _ => [
      _adjustment(ReaderTurnSettings(value: value, onChanged: _apply)),
      _autoTurn(),
      _behavior(ReaderBehaviorCategory.operations),
    ],
  };

  @override
  Widget build(BuildContext context) {
    final preset = _displayPreset;
    final noMotion = _reduceMotion;
    final media = MediaQuery.of(context);
    Widget panel = ReaderSettingsTheme(
      preset: preset,
      child: Theme(
        data: preset.theme(Theme.of(context)),
        child: MediaQuery(
          data: media.copyWith(
            disableAnimations: noMotion,
            highContrast: media.highContrast || preset.isEink,
          ),
          child: Builder(
            builder: (context) {
              final body = SingleChildScrollView(
                key: ValueKey('reader-settings-scroll-${_category ?? 'grid'}'),
                primary: false,
                // Freeze scrolling as well as layout while a value owns the pointer.
                physics: _activeAdjustment == null
                    ? null
                    : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: _items(context),
                ),
              );
              final contents = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _adjustment(
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      child: Row(
                        children: [
                          if (_nested)
                            GlassIconButton(
                              key: const ValueKey('reader-settings-back'),
                              icon: CupertinoIcons.chevron_back,
                              label:
                                  widget.initialSection ==
                                      ReaderSettingsSection.appearance
                                  ? '返回外观分类'
                                  : '返回阅读设置分类',
                              onPressed: _returnCategories,
                            )
                          else
                            const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _title,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          GlassIconButton(
                            key: const ValueKey('reader-settings-close'),
                            icon: CupertinoIcons.xmark,
                            label: '关闭$_title',
                            onPressed: _close,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Flexible(
                    child: SizedBox(
                      key: _bodyKey,
                      child: AnimatedBuilder(
                        animation: _expand,
                        child: body,
                        builder: (context, child) {
                          final progress = _category == null || noMotion
                              ? 1.0
                              : Curves.easeOutCubic.transform(_expand.value);
                          return ClipPath(
                            key: const ValueKey(
                              'reader-settings-category-reveal',
                            ),
                            clipper: ReaderCategoryRevealClipper(
                              _categoryOrigin,
                              _bodyKey,
                              progress,
                            ),
                            child: Opacity(
                              opacity: .35 + progress * .65,
                              child: child,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              );
              final retainedContents = KeyedSubtree(
                key: _contentsKey,
                child: contents,
              );
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: _activeAdjustment == null
                      ? preset.sheetColor
                      : Colors.transparent,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: media.size.height * .82,
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: media.padding.bottom + media.viewInsets.bottom,
                      ),
                      // A zero-duration RenderAnimatedSize notifies from its
                      // own layout on this SDK. Bypass it for reduced motion;
                      // a GlobalKey retains active slider state if that policy
                      // changes at runtime. Preview preserves every layout slot
                      // and therefore does not need a new size transition.
                      child: noMotion
                          ? retainedContents
                          : AnimatedSize(
                              duration: const Duration(milliseconds: 320),
                              alignment: Alignment.topCenter,
                              curve: Curves.easeOutCubic,
                              child: retainedContents,
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    // Keep scope ancestry stable when the user changes paper or runtime
    // motion settings; an active slider must never be remounted mid-pointer.
    panel = PerformanceScope(
      preferences: preset.isEink
          ? const PerformancePreferences(enabled: true)
          : PerformanceScope.of(context),
      explicitReduceMotion: noMotion,
      child: panel,
    );
    return PopScope<void>(
      canPop: !_nested,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _flushAll();
          _endPreview();
          _closing = true;
        } else if (_nested) {
          _returnCategories();
        }
      },
      child: panel,
    );
  }

  Widget _brightnessSlider() {
    const key = ValueKey('reader-brightness');
    void change(double level) {
      if (!_alive || _category != 'page') return;
      setState(
        () => value = value.copyWith(
          brightness: level,
          followSystemBrightness: false,
        ),
      );
      _brightnessPending = true;
      widget.onBrightness(level);
    }

    return _adjustment(
      ReaderValueSlider(
        sliderKey: key,
        label: '亮度',
        value: value.followSystemBrightness
            ? widget.systemBrightness ?? value.brightness
            : value.brightness,
        min: .02,
        max: 1,
        format: (n) => '${(n * 100).round()}%',
        preset: _displayPreset,
        onPreview: change,
        onCommitted: (level) {
          if (!_alive || _category != 'page') return;
          change(level);
          _brightnessPending = false;
          widget.onBrightnessEnd();
        },
        onInteractionChanged: (active) => _preview(key, active),
      ),
      key,
    );
  }

  Widget _followSystem() => Align(
    alignment: Alignment.centerRight,
    child: GlassTextButton(
      key: const ValueKey('reader-follow-system'),
      compact: true,
      selected: value.followSystemBrightness,
      onPressed: () {
        if (!_alive) return;
        _flushAll();
        setState(
          () => value = value.copyWith(
            followSystemBrightness: !value.followSystemBrightness,
          ),
        );
        widget.onFollowSystem();
      },
      child: const Text('跟随系统', style: TextStyle(fontSize: 12)),
    ),
  );

  Widget _autoTurn() => _adjustment(
    ReaderSettingsNavRow(
      key: const ValueKey('reader-auto-turn'),
      label: widget.autoTurnActive ? '停止自动翻页' : '自动翻页',
      icon: widget.autoTurnActive
          ? LucideIcons.circle_pause
          : LucideIcons.circle_play,
      onTap: widget.onAutoTurn == null ? null : () => _close(widget.onAutoTurn),
    ),
  );

  Widget _spacingRow() => ReaderSettingsRow(
    label: '间距',
    child: ReaderSettingsChipRow(
      children: [
        for (final option in const [
          ('compact', '紧凑', 1.5, 6.0, 12.0, 8.0),
          ('standard', '标准', 1.8, 12.0, 20.0, 16.0),
          ('loose', '宽松', 2.1, 20.0, 32.0, 28.0),
        ])
          ReaderSettingsChip(
            key: ValueKey('reader-spacing-${option.$1}'),
            label: option.$2,
            selected:
                (value.lineHeight - option.$3).abs() < .001 &&
                (value.paragraphSpacing - option.$4).abs() < .001 &&
                (value.horizontalPadding - option.$5).abs() < .001 &&
                (value.verticalPadding - option.$6).abs() < .001,
            onTap: () => _apply(
              value.copyWith(
                lineHeight: option.$3,
                paragraphSpacing: option.$4,
                horizontalPadding: option.$5,
                verticalPadding: option.$6,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _backgroundChoices() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final choice in ReaderThemePreset.values)
          Semantics(
            selected: choice == _displayPreset,
            button: true,
            label: '${choice.label}阅读背景',
            child: GlassTextButton(
              key: ValueKey('reader-theme-${choice.name}'),
              selected: choice == _displayPreset,
              onPressed: _backgroundLocked
                  ? null
                  : () => _apply(value.copyWith(themePreset: choice)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: choice.backgroundColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: _displayPreset.borderColor),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(choice.label),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
