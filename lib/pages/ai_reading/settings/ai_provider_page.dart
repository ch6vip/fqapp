import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../services/ai_reading/ai_client.dart';
import '../../../services/ai_reading/ai_credentials.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_settings.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';
import 'ai_settings_widgets.dart';

/// Provider profiles. A profile owns Base URL, models and output mode; the API
/// key itself stays in platform secure storage behind `credentialRef`.
class AiProviderPage extends StatefulWidget {
  const AiProviderPage({super.key});

  @override
  State<AiProviderPage> createState() => _AiProviderPageState();
}

class _AiProviderPageState extends State<AiProviderPage> {
  final _settings = AiSettingsStore.instance;

  Future<void> _edit(AiProviderProfile? profile) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _ProviderEditPage(profile: profile)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return AnimatedBuilder(
      animation: _settings,
      builder: (context, _) {
        final providers = _settings.providers;
        return SettingsScaffold(
          title: '提供商',
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              const SettingsSectionHeader(title: '已配置'),
              const SizedBox(height: 8),
              SettingsGroupCard(
                children: [
                  if (providers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '还没有提供商，先添加一个。',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: palette.muted,
                        ),
                      ),
                    ),
                  for (final profile in providers)
                    SettingsRow(
                      icon: Icons.cloud_outlined,
                      iconTile: true,
                      title: profile.label,
                      subtitle:
                          '${profile.host}，'
                          '${profile.models.isEmpty ? '未配置模型' : profile.models.join('、')}',
                      onTap: () => _edit(profile),
                    ),
                  SettingsRow(
                    icon: Icons.add,
                    iconTile: true,
                    title: '新增提供商',
                    subtitle: '自定义 Base URL、模型与输出模式。',
                    onTap: () => _edit(null),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ProviderEditPage extends StatefulWidget {
  const _ProviderEditPage({this.profile});

  final AiProviderProfile? profile;

  @override
  State<_ProviderEditPage> createState() => _ProviderEditPageState();
}

class _ProviderEditPageState extends State<_ProviderEditPage> {
  final _settings = AiSettingsStore.instance;
  final _credentials = AiCredentialStore.instance;
  final _client = AiChatCompletionsClient();

  late final TextEditingController _label;
  late final TextEditingController _baseUrl;
  late final TextEditingController _models;
  late final TextEditingController _key;
  late final String _draftId;
  late final String _draftRef;
  late AiOutputMode _outputMode;
  late AiReasoningEffort _reasoningEffort;
  late double _temperature;

  bool _saving = false;
  bool _testing = false;
  bool _keySaved = false;
  AiModelCapability? _testResult;
  String? _formError;

  bool get _isNew => widget.profile == null;

  bool get _isDeepSeekEndpoint {
    if (_draftId == 'deepseek') return true;
    final host = Uri.tryParse(_baseUrl.text.trim())?.host.toLowerCase() ?? '';
    return host.endsWith('deepseek.com');
  }

  List<AiReasoningEffort> get _effortOptions => _isDeepSeekEndpoint
      ? const [
          AiReasoningEffort.auto,
          AiReasoningEffort.off,
          AiReasoningEffort.low,
          AiReasoningEffort.high,
          AiReasoningEffort.max,
        ]
      : const [
          AiReasoningEffort.auto,
          AiReasoningEffort.off,
          AiReasoningEffort.low,
          AiReasoningEffort.medium,
          AiReasoningEffort.high,
        ];

  AiReasoningEffort _normalizeEffort(AiReasoningEffort effort) {
    if (_isDeepSeekEndpoint) {
      return effort == AiReasoningEffort.medium
          ? AiReasoningEffort.high
          : effort;
    }
    return effort == AiReasoningEffort.max ? AiReasoningEffort.high : effort;
  }

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _label = TextEditingController(text: profile?.label ?? '');
    _baseUrl = TextEditingController(text: profile?.baseUrl ?? '');
    _models = TextEditingController(text: profile?.models.join(', ') ?? '');
    _key = TextEditingController();
    _outputMode = profile?.outputMode ?? AiOutputMode.jsonObject;
    _draftId = profile?.id ?? _newId();
    _reasoningEffort = _normalizeEffort(
      profile?.reasoningEffort ?? AiReasoningEffort.auto,
    );
    _temperature = profile?.temperature ?? 0.2;
    _draftRef = profile?.credentialRef ?? _newCredentialRef();
    _loadKeyState();
  }

  @override
  void dispose() {
    _label.dispose();
    _baseUrl.dispose();
    _models.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _loadKeyState() async {
    final ref = widget.profile?.credentialRef;
    final saved = await _credentials.has(ref);
    if (!mounted) return;
    setState(() => _keySaved = saved);
  }

  static String _newId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(1 << 32).toRadixString(36);
    return 'p_${now}_$random';
  }

  static String _newCredentialRef() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  List<String> _parsedModels() {
    final seen = <String>{};
    final models = <String>[];
    for (final part in _models.text.split(RegExp(r'[,，\s]+'))) {
      final model = part.trim();
      if (model.isEmpty || !seen.add(model)) continue;
      models.add(model);
    }
    return models;
  }

  AiProviderProfile _buildProfile() {
    final now = DateTime.now();
    final existing = widget.profile;
    return AiProviderProfile(
      id: existing?.id ?? _draftId,
      label: _label.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      credentialRef: existing?.credentialRef ?? _draftRef,
      outputMode: _outputMode,
      temperature: _temperature,
      reasoningEffort: _normalizeEffort(_reasoningEffort),
      models: _parsedModels(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
  }

  Future<void> _editReasoning() async {
    final current = _normalizeEffort(_reasoningEffort);
    final choice = await showAiChoiceDialog(
      context,
      title: '思考等级',
      message: _isDeepSeekEndpoint
          ? 'DeepSeek 支持低、高、最高，对应 low、high、max。'
                '开启思考时温度不生效；需要温度生效时选「关闭」。'
          : '自动不发送参数，沿用服务商默认。'
                '开启思考时温度不一定生效；需要温度生效时选「关闭」。',
      options: [
        for (final effort in _effortOptions)
          (
            key: effort.name,
            label: effort == AiReasoningEffort.auto
                ? '自动（服务商默认）'
                : effort.label,
            selected: current == effort,
          ),
      ],
    );
    if (choice == null || !mounted) return;
    setState(
      () =>
          _reasoningEffort = _normalizeEffort(AiReasoningEffort.parse(choice)),
    );
  }

  Future<void> _editTemperature() async {
    final result = await showAiTemperatureDialog(
      context,
      initial: _temperature,
    );
    if (result == null || !mounted) return;
    setState(() => _temperature = result.value);
  }

  Future<String?> _resolveKey(AiProviderProfile profile) async {
    final typed = _key.text.trim();
    if (typed.isNotEmpty) return typed;
    return _credentials.read(profile.credentialRef);
  }

  Future<AiModelCapability> _probe(
    AiProviderProfile profile,
    String apiKey,
    String model,
  ) => _client.probe(
    profile: profile,
    apiKey: apiKey,
    model: model,
    outputMode: _outputMode,
    timeout: Duration(seconds: _settings.global.requestTimeoutSeconds),
  );

  String? _validateInput({required bool requireKey}) {
    if (_label.text.trim().isEmpty) return '请填写提供商名称';
    final baseUrl = _baseUrl.text.trim();
    try {
      AiChatCompletionsClient.validateBaseUrl(baseUrl);
    } on AiNetworkException catch (error) {
      return error.message;
    } catch (error) {
      return 'Base URL 无效：$error';
    }
    if (_parsedModels().isEmpty) return '请至少填写一个模型';
    if (requireKey && _key.text.trim().isEmpty && !_keySaved) {
      return '请填写 API Key';
    }
    return null;
  }

  Future<void> _test() async {
    if (_testing || _saving) return;
    final error = _validateInput(requireKey: true);
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    final profile = _buildProfile();
    final apiKey = await _resolveKey(profile);
    if (apiKey == null) {
      if (!mounted) return;
      setState(() => _formError = '还没有保存 API Key');
      return;
    }
    setState(() {
      _testing = true;
      _formError = null;
      _testResult = null;
    });
    try {
      final capability = await _probe(profile, apiKey, profile.models.first);
      await _settings.saveCapability(capability);
      if (!mounted) return;
      setState(() => _testResult = capability);
      aiShowSnack(
        context,
        capability.ok ? '连接通过，已记录能力' : '连接失败：${capability.detail ?? '未知原因'}',
      );
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '测试连接失败：$error');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _testing) return;
    final error = _validateInput(requireKey: false);
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    final profile = _buildProfile();
    final key = _key.text.trim();
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      if (_outputMode == AiOutputMode.jsonSchema) {
        final apiKey = await _resolveKey(profile);
        if (apiKey == null) {
          setState(() => _formError = 'json_schema 需要先填写 API Key 并测试通过');
          return;
        }
        final capability = await _probe(profile, apiKey, profile.models.first);
        await _settings.saveCapability(capability);
        if (!capability.ok) {
          if (!mounted) return;
          setState(() {
            _formError =
                'json_schema 未通过，未保存：${capability.detail ?? '未知原因'}。'
                '不会自动降级，请改用 json_object 或换端点。';
            _testResult = capability;
          });
          return;
        }
        if (!mounted) return;
        setState(() => _testResult = capability);
      }
      await _settings.upsertProvider(profile);
      if (key.isNotEmpty) {
        await _credentials.write(profile.credentialRef, key);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '保存提供商失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final profile = widget.profile;
    if (profile == null) return;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '删除提供商？',
      message:
          '若已有书引用此提供商，这些书会显示配置失效，需要重新选择。'
          'API Key 会从系统安全存储删除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await _settings.deleteProvider(profile.id);
      await _credentials.delete(profile.credentialRef);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '删除失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final testResult = _testResult;
    return SettingsScaffold(
      title: _isNew ? '新增提供商' : '编辑提供商',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          SettingsGroupCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: TextField(
                  controller: _label,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    hintText: '例如 DeepSeek',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: TextField(
                  controller: _baseUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.example.com/v1',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: TextField(
                  controller: _models,
                  decoration: const InputDecoration(
                    labelText: '模型',
                    hintText: 'deepseek-flash, deepseek-v4-pro',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: TextField(
                  controller: _key,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: _keySaved ? '已保存，留空保持不变' : '粘贴 API Key',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '输出模式',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final mode in AiOutputMode.values)
                          ChoiceChip(
                            label: Text(mode.wire),
                            selected: _outputMode == mode,
                            selectedColor: palette.soft,
                            side: BorderSide(color: palette.line, width: 0.6),
                            onSelected: _saving
                                ? null
                                : (_) => setState(() => _outputMode = mode),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsGroupCard(
            children: [
              SettingsRow(
                icon: Icons.psychology_outlined,
                title: '思考等级',
                value:
                    _normalizeEffort(_reasoningEffort) == AiReasoningEffort.auto
                    ? '自动'
                    : _normalizeEffort(_reasoningEffort).label,
                onTap: _saving ? null : _editReasoning,
              ),
              SettingsRow(
                icon: Icons.thermostat_outlined,
                title: '温度',
                value: _temperature.toStringAsFixed(1),
                onTap: _saving ? null : _editTemperature,
              ),
            ],
          ),
          if (_formError case final error?) ...[
            const SizedBox(height: 12),
            AiInfoCard(
              title: '还不能保存',
              body: error,
              tone: AiStatusTone.error,
              icon: Icons.error_outline,
            ),
          ],
          if (testResult != null) ...[
            const SizedBox(height: 12),
            AiInfoCard(
              title: testResult.ok ? '连接测试通过' : '连接测试失败',
              body: testResult.ok
                  ? '已记录 ${testResult.modelId} 的 ${testResult.outputMode.wire} 能力。'
                  : testResult.detail ?? '未知原因',
              tone: testResult.ok ? AiStatusTone.ok : AiStatusTone.error,
              icon: testResult.ok
                  ? Icons.check_circle_outline
                  : Icons.cancel_outlined,
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving || _testing ? null : _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            child: Text(_saving ? '保存中' : '保存提供商'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _saving || _testing ? null : _test,
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.ink,
              side: BorderSide(color: palette.line),
              minimumSize: const Size.fromHeight(46),
            ),
            child: Text(_testing ? '测试中' : '测试连接'),
          ),
          if (!_isNew) ...[
            const SizedBox(height: 20),
            SettingsGroupCard(
              children: [
                SettingsRow(
                  icon: Icons.delete_outline,
                  title: '删除提供商',
                  subtitle: '同时删除 API Key',
                  onTap: _delete,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
