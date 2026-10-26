import 'package:flutter/material.dart';

import '../services/system_tts.dart';

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

  Future<void> _save(SystemTtsPreferences prefs) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await prefs.save();
      if (mounted) setState(() => _prefs = prefs);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置保存失败，请重试')));
      }
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
    return Scaffold(
      appBar: AppBar(title: const Text('系统朗读')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '从小说或本地书阅读页点“听书”即可使用。支持已安装的系统 TTS 引擎，例如 MultiTTS；音色和联网需求由引擎管理。',
                ),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  Text(_error!),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ] else if (_engines.isEmpty)
                  const Text('没有找到朗读引擎，请先安装并在引擎应用中配置中文语音。')
                else ...[
                  if (selectedMissing)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('之前选择的引擎已不可用，请重新选择。'),
                    ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_prefs.engine ?? ''),
                    initialValue: selectedMissing
                        ? null
                        : (_prefs.engine ?? ''),
                    decoration: const InputDecoration(labelText: '朗读引擎'),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(
                          '系统默认${defaultLabel == null ? '' : ' · $defaultLabel'}',
                        ),
                      ),
                      for (final engine in _engines)
                        DropdownMenuItem(
                          value: engine.package,
                          child: Text(
                            engine.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    isExpanded: true,
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value == null) return;
                            _save(
                              SystemTtsPreferences(
                                engine: value.isEmpty ? null : value,
                                rate: _prefs.rate,
                              ),
                            );
                          },
                  ),
                  const SizedBox(height: 16),
                  Text('语速 ${_prefs.rate.toStringAsFixed(1)}×'),
                  Slider(
                    value: _prefs.rate,
                    min: 0.5,
                    max: 3,
                    divisions: 25,
                    label: '${_prefs.rate.toStringAsFixed(1)}×',
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
                            SystemTtsPreferences(
                              engine: _prefs.engine,
                              rate: value,
                            ),
                          ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text('引擎和语速修改在关闭当前系统朗读、重新开始后生效。部分引擎暂停后会从当前短句重读。'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_voice),
                  label: const Text('打开系统语音设置'),
                ),
              ],
            ),
    );
  }
}
