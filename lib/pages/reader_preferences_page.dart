import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/linux_platform.dart' show isLinuxDesktop;
import '../services/reader_device.dart';
import '../services/reader_preferences.dart';
import '../widgets/home/home_design.dart';
import '../widgets/reader/reader_tap_zone_sheet.dart';
import '../widgets/reader/reader_theme.dart';
import '../widgets/reader/reader_value_slider.dart';
import '../widgets/reader/settings/reader_font_picker_sheet.dart';
import '../widgets/reader/settings/reader_settings_widgets.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/wenku/wenku_ui.dart';

class ReaderPreferencesPage extends StatefulWidget {
  const ReaderPreferencesPage({super.key});

  @override
  State<ReaderPreferencesPage> createState() => _ReaderPreferencesPageState();
}

class _ReaderPreferencesPageState extends State<ReaderPreferencesPage>
    with WidgetsBindingObserver {
  ReaderPreferences _value = const ReaderPreferences();
  final ReaderDevice _device = ReaderDevice();
  final _brightnessListenable = ValueNotifier<ReaderDeviceStatus?>(null);
  bool _deviceAvailable = false;
  StreamSubscription<ReaderDeviceStatus>? _deviceSubscription;
  int _deviceGeneration = 0;
  bool _appActive = true;
  Timer? _saveTimer;
  bool _loading = true;
  bool _loadFailed = false;
  bool _dirty = false;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await ReaderPreferences.load();
      if (!mounted) return;
      setState(() {
        _value = value;
        _loadFailed = false;
      });
      await _startDevice();
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startDevice() async {
    if (!_appActive) return;
    final generation = ++_deviceGeneration;
    final status = await _device.start(
      followSystem: _value.followSystemBrightness,
      brightness: _value.brightness,
    );
    if (!mounted || !_appActive || generation != _deviceGeneration) return;
    setState(() => _deviceAvailable = status != null && !isLinuxDesktop);
    _brightnessListenable.value = status;
    if (status != null) {
      _deviceSubscription ??= _device.changes.listen((status) {
        if (mounted && _appActive) _brightnessListenable.value = status;
      }, onError: (Object _) {});
    }
    await _device.keepScreenOn(_value.keepScreenOn);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (_appActive) {
      if (!_loading && !_loadFailed) unawaited(_startDevice());
    } else {
      ++_deviceGeneration;
      unawaited(_save());
      unawaited(_device.keepScreenOn(false));
      unawaited(_device.suspend());
    }
  }

  void _apply(ReaderPreferences Function(ReaderPreferences) change) {
    if (!mounted || _loading || _loadFailed) return;
    final previous = _value;
    final next = change(_value).normalized();
    setState(() => _value = next);
    _dirty = true;
    _saveFailed = false;
    if (previous.brightness != next.brightness ||
        previous.followSystemBrightness != next.followSystemBrightness) {
      unawaited(
        _device
            .setBrightness(
              followSystem: next.followSystemBrightness,
              brightness: next.brightness,
            )
            .then((applied) {
              if (!applied && mounted && !isLinuxDesktop) {
                _showMessage('暂时无法调整亮度，请重新进入本页');
              }
            }),
      );
    }
    if (previous.keepScreenOn != next.keepScreenOn) {
      unawaited(_device.keepScreenOn(next.keepScreenOn));
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 220), _save);
  }

  Future<void> _save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty) return;
    final snapshot = _value;
    _dirty = false;
    try {
      await snapshot.save();
    } catch (_) {
      _dirty = true;
      if (mounted && !_saveFailed) {
        _saveFailed = true;
        _showMessage('阅读设置保存失败，请稍后再修改一次');
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickFont() async {
    final selection = await showReaderFontPicker(
      context: context,
      preset: _value.themePreset,
      currentPath: _value.fontPath,
      currentName: _value.fontName,
      onPickFont: _device.pickFont,
    );
    if (selection == null || !mounted) return;
    if (selection.path.isNotEmpty) {
      try {
        await ReaderFonts.load(selection.path);
      } on ReaderFontLimitException {
        _showMessage('已导入字体过多，重启应用后可继续更换字体');
        return;
      } catch (_) {
        _showMessage('字体无法读取，请选择有效的 TTF、OTF 或 TTC 文件');
        return;
      }
    }
    _apply(
      (value) => value.copyWith(
        fontPath: selection.path,
        fontName: selection.name,
        builtinSerifFont: false,
      ),
    );
  }

  Future<void> _editTapZones() async {
    final zones = await showReaderTapZoneEditor(
      context: context,
      initialZones: _value.tapZones,
      preset: _value.themePreset,
    );
    if (zones != null && mounted) {
      _apply((value) => value.copyWith(tapZones: zones));
    }
  }

  Future<void> _editCustomBackground() async {
    if (_backgroundLocked) return;
    var hex = _paperHex;
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义纸色'),
        scrollable: true,
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: hex,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-F]')),
              LengthLimitingTextInputFormatter(7),
            ],
            onChanged: (value) => hex = value,
            validator: (value) =>
                RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(value ?? '')
                ? null
                : '请输入 6 位颜色值，例如 #F3E4C2',
            decoration: const InputDecoration(
              labelText: 'HEX',
              hintText: '#F3E4C2',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              final raw = hex.replaceFirst('#', '');
              Navigator.pop(context, int.parse('FF$raw', radix: 16));
            },
            child: const Text('使用'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      _apply(
        (preferences) => preferences.copyWith(
          customBackgroundColor: result,
          themePreset: Color(result).computeLuminance() <= 0.179
              ? ReaderThemePreset.dark
              : ReaderThemePreset.light,
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_deviceGeneration;
    _saveTimer?.cancel();
    unawaited(_save());
    unawaited(_deviceSubscription?.cancel());
    unawaited(_device.keepScreenOn(false));
    unawaited(_device.close());
    _brightnessListenable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppFeaturePage(
      title: '小说阅读器',
      code: 'READING / APPEARANCE',
      child: ReaderSettingsTheme(
        preset: _settingsPreset,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadFailed
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('阅读设置读取失败'),
                    TextButton(
                      onPressed: () {
                        setState(() => _loading = true);
                        unawaited(_load());
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
              )
            : _buildPage(context),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const PageStorageKey('reader-preferences-page'),
          padding: featurePadding(context),
          children: [
            _card([
              _heading('阅读外观', '纸色、翻页与字体', icon: LucideIcons.book_open),
              _themeChoices(),
              if (_backgroundLocked)
                const ReaderSettingsSectionHeader(title: '全局显示模式已接管阅读纸色'),
              if (_value.customBackgroundColor != null)
                _navRow(
                  label: '恢复预设纸色',
                  onTap: () => _apply(
                    (value) => value.copyWith(clearCustomBackground: true),
                  ),
                ),
              _choiceRow(
                label: '阅读方式',
                choices: [
                  _Choice('上下滚动', _value.pageMode == ReaderPageMode.scroll),
                  _Choice('左右翻页', _value.pageMode == ReaderPageMode.paged),
                ],
                onSelected: (index) => _apply(
                  (value) => value.copyWith(
                    pageMode: index == 0
                        ? ReaderPageMode.scroll
                        : ReaderPageMode.paged,
                  ),
                ),
              ),
              _navRow(
                label: '自定义纸色',
                value: _paperHex,
                leading: _paperSwatch,
                enabled: !_backgroundLocked,
                onTap: _editCustomBackground,
              ),
              if (_value.pageMode == ReaderPageMode.paged)
                _choiceRow(
                  label: '翻页动画',
                  choices: [
                    _Choice(
                      '平移',
                      _value.pageTurnStyle == ReaderPageTurnStyle.slide,
                    ),
                    _Choice(
                      '覆盖',
                      _value.pageTurnStyle == ReaderPageTurnStyle.cover,
                    ),
                    _Choice(
                      '仿真',
                      _value.pageTurnStyle == ReaderPageTurnStyle.curl,
                    ),
                    _Choice(
                      '无动画',
                      _value.pageTurnStyle == ReaderPageTurnStyle.none,
                    ),
                  ],
                  onSelected: (index) => _apply(
                    (value) => value.copyWith(
                      pageTurnStyle: ReaderPageTurnStyle.values.firstWhere(
                        (style) => switch (index) {
                          0 => style == ReaderPageTurnStyle.slide,
                          1 => style == ReaderPageTurnStyle.cover,
                          2 => style == ReaderPageTurnStyle.curl,
                          _ => style == ReaderPageTurnStyle.none,
                        },
                      ),
                      instantSwipeTurn: false,
                    ),
                  ),
                ),
              _navRow(label: '字体', value: _fontLabel, onTap: _pickFont),
              _choiceRow(
                label: '内置字体',
                choices: [
                  _Choice(
                    '系统',
                    !_value.builtinSerifFont && _value.fontPath.isEmpty,
                  ),
                  _Choice('宋体', _value.builtinSerifFont),
                ],
                onSelected: (index) => _apply(
                  (value) => value.copyWith(
                    builtinSerifFont: index == 1,
                    fontPath: '',
                    fontName: '',
                  ),
                ),
              ),
              _switchRow(
                '段首缩进',
                _value.firstLineIndent,
                (enabled) =>
                    _apply((value) => value.copyWith(firstLineIndent: enabled)),
              ),
              _switchRow(
                '两端对齐',
                _value.justifyText,
                (enabled) =>
                    _apply((value) => value.copyWith(justifyText: enabled)),
              ),
              if (_value.pageMode == ReaderPageMode.scroll)
                _choiceRow(
                  label: '滚动跨章',
                  choices: [
                    _Choice(
                      '分割线拼接',
                      _value.scrollChapterMode ==
                          ReaderScrollChapterMode.joined,
                    ),
                    _Choice(
                      '直接切换',
                      _value.scrollChapterMode ==
                          ReaderScrollChapterMode.replace,
                    ),
                  ],
                  onSelected: (index) => _apply(
                    (value) => value.copyWith(
                      scrollChapterMode: index == 0
                          ? ReaderScrollChapterMode.joined
                          : ReaderScrollChapterMode.replace,
                    ),
                  ),
                ),
              _switchRow(
                '连续阅读',
                _value.continuousReading,
                (enabled) => _apply(
                  (value) => value.copyWith(continuousReading: enabled),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            _card([
              _heading('本机显示', '只保存在这台设备上', icon: LucideIcons.smartphone),
              ValueListenableBuilder<ReaderDeviceStatus?>(
                valueListenable: _brightnessListenable,
                builder: (context, status, _) => Column(
                  children: [
                    _sliderRow(
                      label: '阅读亮度',
                      value: _value.followSystemBrightness
                          ? status?.systemBrightness ?? _value.brightness
                          : _value.brightness,
                      min: 0.02,
                      max: 1,
                      divisions: 49,
                      format: (value) => '${(value * 100).round()}%',
                      onChanged: _deviceAvailable
                          ? (value) => _apply(
                              (preferences) => preferences.copyWith(
                                brightness: value,
                                followSystemBrightness: false,
                              ),
                            )
                          : null,
                    ),
                    if (!_loading && !_deviceAvailable)
                      const ReaderSettingsRow(
                        label: '设备亮度',
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            '当前平台不可用',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _switchRow(
                '跟随系统亮度',
                _value.followSystemBrightness,
                _deviceAvailable
                    ? (enabled) => _apply(
                        (value) =>
                            value.copyWith(followSystemBrightness: enabled),
                      )
                    : null,
              ),
              _switchRow(
                '阅读时保持屏幕常亮',
                _value.keepScreenOn,
                (enabled) =>
                    _apply((value) => value.copyWith(keepScreenOn: enabled)),
              ),
              _switchRow(
                '系统状态栏',
                _value.showSystemStatusBar,
                (enabled) => _apply(
                  (value) => value.copyWith(showSystemStatusBar: enabled),
                ),
              ),
              _switchRow(
                '底部导航栏',
                _value.showSystemNavigationBar,
                (enabled) => _apply(
                  (value) => value.copyWith(showSystemNavigationBar: enabled),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            _card([
              _heading(
                '版面与操作',
                '字号、间距和翻页手势',
                icon: LucideIcons.sliders_horizontal,
              ),
              _sliderRow(
                label: '字号',
                value: _value.fontSize,
                min: 14,
                max: 32,
                divisions: 18,
                format: (value) => '${value.round()}',
                onChanged: (value) => _apply(
                  (preferences) => preferences.copyWith(
                    fontSize: value,
                    titleSize: value + 2,
                  ),
                ),
              ),
              _choiceRow(
                label: '字重',
                choices: [
                  for (final entry in const {
                    300: '细',
                    400: '常规',
                    500: '中等',
                    600: '粗',
                    700: '加粗',
                  }.entries)
                    _Choice(entry.value, _value.fontWeight == entry.key),
                ],
                onSelected: (index) => _apply(
                  (value) => value.copyWith(
                    fontWeight: const [300, 400, 500, 600, 700][index],
                  ),
                ),
              ),
              _sliderRow(
                label: '行距',
                value: _value.lineHeight,
                min: 1.2,
                max: 2.4,
                divisions: 12,
                format: (value) => value.toStringAsFixed(1),
                onChanged: (value) => _apply(
                  (preferences) => preferences.copyWith(lineHeight: value),
                ),
              ),
              _sliderRow(
                label: '段距',
                value: _value.paragraphSpacing,
                min: 0,
                max: 32,
                divisions: 16,
                format: (value) => value.round().toString(),
                onChanged: (value) => _apply(
                  (preferences) =>
                      preferences.copyWith(paragraphSpacing: value),
                ),
              ),
              _sliderRow(
                label: '字距',
                value: _value.letterSpacing,
                min: -0.5,
                max: 3,
                divisions: 35,
                format: (value) => value.toStringAsFixed(1),
                onChanged: (value) => _apply(
                  (preferences) => preferences.copyWith(letterSpacing: value),
                ),
              ),
              _sliderRow(
                label: '左右边距',
                value: _value.horizontalPadding,
                min: 8,
                max: 48,
                divisions: 20,
                format: (value) => value.round().toString(),
                onChanged: (value) => _apply(
                  (preferences) =>
                      preferences.copyWith(horizontalPadding: value),
                ),
              ),
              _sliderRow(
                label: '上下边距',
                value: _value.verticalPadding,
                min: 0,
                max: 64,
                divisions: 16,
                format: (value) => value.round().toString(),
                onChanged: (value) => _apply(
                  (preferences) => preferences.copyWith(verticalPadding: value),
                ),
              ),
              _stepperRow(
                label: '标题字号',
                value: _value.titleSize.round(),
                min: 16,
                max: 40,
                onChanged: (value) => _apply(
                  (preferences) =>
                      preferences.copyWith(titleSize: value.toDouble()),
                ),
              ),
              _choiceRow(
                label: '章名对齐',
                choices: [
                  _Choice(
                    '靠左',
                    _value.titleAlignment == ReaderTitleAlignment.start,
                  ),
                  _Choice(
                    '居中',
                    _value.titleAlignment == ReaderTitleAlignment.center,
                  ),
                ],
                onSelected: (index) => _apply(
                  (value) => value.copyWith(
                    titleAlignment: index == 0
                        ? ReaderTitleAlignment.start
                        : ReaderTitleAlignment.center,
                  ),
                ),
              ),
              _stepperRow(
                label: '自动翻页间隔',
                value: _value.autoTurnSeconds,
                suffix: '秒',
                min: 3,
                max: 60,
                onChanged: (value) => _apply(
                  (preferences) => preferences.copyWith(autoTurnSeconds: value),
                ),
              ),
              _switchRow(
                '音量键翻页',
                _value.volumeKeyTurn,
                (enabled) =>
                    _apply((value) => value.copyWith(volumeKeyTurn: enabled)),
              ),
              _choiceRow(
                label: '阅读信息',
                choices: [
                  _Choice(
                    '隐藏',
                    _value.readingInfoMode == ReaderInfoMode.hidden,
                  ),
                  _Choice(
                    '简洁',
                    _value.readingInfoMode == ReaderInfoMode.compact,
                  ),
                  _Choice(
                    '详细',
                    _value.readingInfoMode == ReaderInfoMode.detailed,
                  ),
                ],
                onSelected: (index) => _apply(
                  (value) => value.copyWith(
                    readingInfoMode: ReaderInfoMode.values[index],
                  ),
                ),
              ),
              _switchRow(
                '显示段评',
                _value.showParagraphBubbles,
                (enabled) => _apply(
                  (value) => value.copyWith(showParagraphBubbles: enabled),
                ),
              ),
              _navRow(label: '点击区域', onTap: _editTapZones),
            ]),
          ],
        ),
      ),
    );
  }

  String get _fontLabel {
    if (_value.builtinSerifFont) return '宋体';
    if (_value.fontName.isNotEmpty) return _value.fontName;
    return '系统字体';
  }

  String get _paperHex {
    final color = _backgroundLocked
        ? _selectedPreset.backgroundColor.toARGB32()
        : _value.customBackgroundColor ??
              _value.themePreset.backgroundColor.toARGB32();
    return '#${color.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
  }

  Widget get _paperSwatch => Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      color: _backgroundLocked
          ? _selectedPreset.backgroundColor
          : _value.effectiveBackgroundColor,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: _settingsPreset.borderColor),
    ),
  );

  ReaderThemePreset get _settingsPreset {
    final palette = HomePalette.of(context);
    if (palette.eink) return ReaderThemePreset.eink;
    return palette.dark ? ReaderThemePreset.dark : ReaderThemePreset.light;
  }

  bool get _backgroundLocked {
    final palette = HomePalette.of(context);
    return palette.eink || (palette.dark && palette.oled);
  }

  ReaderThemePreset get _selectedPreset =>
      _backgroundLocked ? _settingsPreset : _value.themePreset;

  Widget _card(List<Widget> children) => SurfacePanel(
    ink: true,
    padding: const EdgeInsets.symmetric(vertical: 6),
    radius: 16,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _heading(String title, String subtitle, {required IconData icon}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Row(
          children: [
            Icon(icon, size: 19, color: _settingsPreset.accentColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _themeChoices() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 8.0;
        final scale = MediaQuery.textScalerOf(context).scale(11) / 11;
        final columns = (6 / scale).floor().clamp(2, 6);
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final preset in ReaderThemePreset.values)
              Semantics(
                button: !_backgroundLocked,
                enabled: !_backgroundLocked,
                selected:
                    (_backgroundLocked ||
                        _value.customBackgroundColor == null) &&
                    _selectedPreset == preset,
                label: '${preset.label}阅读背景',
                child: InkWell(
                  onTap: _backgroundLocked
                      ? null
                      : () => _apply(
                          (value) => value.copyWith(
                            themePreset: preset,
                            clearCustomBackground: true,
                          ),
                        ),
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: width,
                    height: 44,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: preset.backgroundColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color:
                              (_backgroundLocked ||
                                      _value.customBackgroundColor == null) &&
                                  _selectedPreset == preset
                              ? preset.accentColor
                              : preset.borderColor,
                          width:
                              (_backgroundLocked ||
                                      _value.customBackgroundColor == null) &&
                                  _selectedPreset == preset
                              ? 1.5
                              : 0.8,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          preset.label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: preset.textColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );

  Widget _choiceRow({
    required String label,
    required List<_Choice> choices,
    required ValueChanged<int> onSelected,
  }) => ReaderSettingsRow(
    label: label,
    child: ReaderSettingsChipRow(
      children: [
        for (var index = 0; index < choices.length; index++)
          ReaderSettingsChip(
            key: ValueKey('reader-pref-${label.hashCode}-$index'),
            label: choices[index].label,
            selected: choices[index].selected,
            onTap: () => onSelected(index),
          ),
      ],
    ),
  );

  Widget _switchRow(String label, bool value, ValueChanged<bool>? onChanged) =>
      onChanged == null
      ? ReaderSettingsRow(
          label: label,
          child: const Align(
            alignment: Alignment.centerRight,
            child: Text('当前平台不可用', style: TextStyle(fontSize: 12)),
          ),
        )
      : ReaderSettingsSwitchRow(
          key: ValueKey('reader-pref-switch-${label.hashCode}'),
          label: label,
          value: value,
          onChanged: onChanged,
        );

  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double>? onChanged,
  }) => ReaderSettingsRow(
    label: label,
    child: ReaderValueSlider(
      sliderKey: ValueKey('reader-pref-slider-${label.hashCode}'),
      label: label,
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      format: format,
      onCommitted: onChanged,
      inline: true,
      leading: const SizedBox.shrink(),
      preset: _settingsPreset,
    ),
  );

  Widget _stepperRow({
    required String label,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
    String suffix = '',
  }) => ReaderSettingsRow(
    label: label,
    child: ReaderSettingsStepper(
      value: '$value$suffix',
      decreaseTooltip: '减小$label',
      increaseTooltip: '增大$label',
      onDecrease: value > min ? () => onChanged(value - 1) : null,
      onIncrease: value < max ? () => onChanged(value + 1) : null,
    ),
  );

  Widget _navRow({
    required String label,
    String? value,
    required VoidCallback onTap,
    Widget? leading,
    bool enabled = true,
  }) => InkWell(
    onTap: enabled ? onTap : null,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 10)],
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: enabled ? null : Theme.of(context).disabledColor,
              ),
            ),
          ),
          if (value != null) ...[
            Flexible(
              child: Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Icon(
            LucideIcons.chevron_right,
            size: 18,
            color: enabled ? null : Theme.of(context).disabledColor,
          ),
        ],
      ),
    ),
  );
}

class _Choice {
  const _Choice(this.label, this.selected);

  final String label;
  final bool selected;
}
