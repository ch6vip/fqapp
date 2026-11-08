// 系统朗读设置页。
//
// Two presentations, one preference model. Classic restores the pre-#291
// `SettingsScaffold` layout from fqapp-backup@f329399 (Material dropdown, plain
// slider, outlined system-settings button); archive keeps the ported Wenku8
// rev ebcd7f1 surfaces (`ArchiveFeaturePage`, `SettingsPanel`,
// `GlassSettingMenu`, `GlassControls.slider`, `ContentNotice`). Both go through
// `SettingsArchivePage`, whose classic shell hides the back affordance in the
// Windows right pane.
//
// `SystemTts` / `SystemTtsPreferences` and the generation-guarded load are
// unchanged.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/audio_floating_routes.dart';
import '../services/system_tts.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_adaptive.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_archive_rows.dart';
import '../widgets/wenku/wenku_ui.dart';

class SystemTtsSettingsPage extends StatefulWidget {
  const SystemTtsSettingsPage({super.key});

  @override
  State<SystemTtsSettingsPage> createState() => _SystemTtsSettingsPageState();
}

class _SystemTtsSettingsPageState extends State<SystemTtsSettingsPage>
    with WidgetsBindingObserver {
  List<SystemTtsEngine> _engines = const [];
  String? _defaultEngine;
  SystemTtsPreferences _prefs = const SystemTtsPreferences();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _generation = 0;

  // Official AudioPlaySettingActivity hides the capsule.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AudioFloatingRouteScope.configure(context, hidden: true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_saving) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prefs = await SystemTtsPreferences.load();
      final data = await SystemTts.engines();
      if (!mounted || generation != _generation) return;
      setState(() {
        _prefs = prefs;
        _engines = data.engines;
        _defaultEngine = data.defaultEngine;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = SystemTts.errorMessage(e);
      });
    }
  }

  /// Persists [prefs]. Returns whether the write landed: a failed write must
  /// leave `_prefs` (and the controlled dropdown) on the committed value.
  Future<bool> _save(SystemTtsPreferences prefs) async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      await prefs.save();
      if (mounted) setState(() => _prefs = prefs);
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置保存失败，请重试')));
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openSettings() async {
    try {
      await SystemTts.openSettings();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(SystemTts.errorMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedMissing =
        _prefs.engine != null &&
        !_engines.any((e) => e.package == _prefs.engine);
    final defaultLabel = _engines
        .where((e) => e.package == _defaultEngine)
        .firstOrNull
        ?.label;
    return SettingsArchivePage(
      title: '系统朗读',
      code: 'AUDIO / SYSTEM ENGINES',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: featurePadding(context),
                  children: [
                    const SettingsHint(
                      '从小说或本地书阅读页点“听书”即可使用。支持已安装的系统 TTS '
                      '引擎，例如 MultiTTS；音色和联网需求由引擎管理。',
                    ),
                    const SizedBox(height: 16),
                    if (_error case final error?)
                      SettingsNotice(
                        icon: CupertinoIcons.wifi_exclamationmark,
                        classicIcon: LucideIcons.circle_alert,
                        title: '无法读取朗读引擎',
                        message: error,
                        actionLabel: '重试',
                        onAction: _load,
                      )
                    else if (_engines.isEmpty)
                      const SettingsNotice(
                        icon: CupertinoIcons.volume_off,
                        classicIcon: LucideIcons.volume_x,
                        title: '没有找到朗读引擎',
                        message: '请先安装并在引擎应用中配置中文语音。',
                      )
                    else ...[
                      SettingsCard(
                        children: [
                          if (selectedMissing)
                            SettingsCardRow(
                              classicPadding: const EdgeInsets.fromLTRB(
                                16,
                                14,
                                16,
                                0,
                              ),
                              child: SettingsHint(
                                '之前选择的引擎已不可用，请重新选择。',
                                emphasis: true,
                              ),
                            ),
                          _enginePicker(selectedMissing, defaultLabel),
                          _ratePicker(),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const SettingsHint(
                        '引擎和语速修改在关闭当前系统朗读、重新开始后生效。'
                        '部分引擎暂停后会从当前短句重读。',
                      ),
                    ],
                    const SizedBox(height: 20),
                    Center(
                      child: SettingsAction(
                        label: '打开系统语音设置',
                        icon: LucideIcons.settings_2,
                        style: SettingsActionStyle.outlined,
                        expand: true,
                        onPressed: _openSettings,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _enginePicker(bool selectedMissing, String? defaultLabel) {
    final missingEngine = selectedMissing ? _prefs.engine : null;
    final options = <String, String>{
      '': '系统默认${defaultLabel == null ? '' : ' · $defaultLabel'}',
      for (final engine in _engines) engine.package: engine.label,
      ?missingEngine: '已不可用 · $missingEngine',
    };
    if (AppUiScope.isClassic(context)) {
      // The pre-#291 page used a Material dropdown inside the settings card.
      // It is controlled by `_prefs.engine`, so a failed write shows the
      // committed engine again instead of the unsubmitted choice (the old
      // `DropdownButtonFormField` kept the failed value in its own state).
      final selected = options.containsKey(_prefs.engine ?? '')
          ? _prefs.engine ?? ''
          : '';
      return SettingsCardRow(
        classicPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: InputDecorator(
          decoration: const InputDecoration(labelText: '朗读引擎'),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: const ValueKey('tts-engine-classic'),
              value: selected,
              isExpanded: true,
              items: [
                for (final option in options.entries)
                  DropdownMenuItem(
                    value: option.key,
                    child: Text(option.value, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null || value == selected) return;
                      unawaited(
                        _save(
                          SystemTtsPreferences(
                            engine: value.isEmpty ? null : value,
                            rate: _prefs.rate,
                          ),
                        ),
                      );
                    },
            ),
          ),
        ),
      );
    }
    return GlassSettingMenu<String>(
      icon: CupertinoIcons.waveform,
      label: '朗读引擎',
      value: _prefs.engine ?? '',
      options: options,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      onChanged: _saving
          ? (_) {}
          : (value) => _save(
              SystemTtsPreferences(
                engine: value.isEmpty ? null : value,
                rate: _prefs.rate,
              ),
            ),
    );
  }

  Widget _ratePicker() {
    final rate = _prefs.rate;
    if (AppUiScope.isClassic(context)) {
      final palette = HomePalette.of(context);
      return SettingsCardRow(
        classicPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '语速 ${rate.toStringAsFixed(1)}×',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
            Slider(
              value: rate,
              min: 0.5,
              max: 3,
              divisions: 25,
              label: '${rate.toStringAsFixed(1)}×',
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                      _prefs = SystemTtsPreferences(
                        engine: _prefs.engine,
                        rate: value,
                      );
                    }),
              onChangeEnd: _saving
                  ? null
                  : (value) => _save(
                      SystemTtsPreferences(engine: _prefs.engine, rate: value),
                    ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: AppText(
                '语速',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            AppText(
              '${rate.toStringAsFixed(1)}×',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        GlassControls.slider(
          context,
          value: rate,
          min: .5,
          max: 3,
          divisions: 25,
          onChanged: _saving
              ? null
              : (value) => setState(() {
                  _prefs = SystemTtsPreferences(
                    engine: _prefs.engine,
                    rate: value,
                  );
                }),
          onChangeEnd: _saving
              ? null
              : (value) => _save(
                  SystemTtsPreferences(engine: _prefs.engine, rate: value),
                ),
        ),
      ],
    );
  }
}
