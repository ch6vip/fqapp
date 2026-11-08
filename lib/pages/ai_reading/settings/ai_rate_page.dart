import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_settings.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';

/// Editable per-provider/per-model price table. Prices are entered in currency
/// units per one million tokens and stored as integer micro-units.
class AiRatePage extends StatefulWidget {
  const AiRatePage({super.key});

  @override
  State<AiRatePage> createState() => _AiRatePageState();
}

class _AiRatePageState extends State<AiRatePage> {
  final _settings = AiSettingsStore.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _settings.init();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit([AiRateProfile? initial]) async {
    final result = await showDialog<AiRateProfile>(
      context: context,
      builder: (_) => _RateEditor(initial: initial, settings: _settings),
    );
    if (result == null || !mounted) return;
    await _settings.upsertRate(result);
    if (mounted) setState(() {});
  }

  Future<void> _delete(AiRateProfile rate) async {
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '删除费率？',
      message: '历史请求仍保留当时的费率快照，新请求不再使用这条费率。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _settings.deleteRate(rate.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final rates = _settings.rates;
    return SettingsScaffold(
      title: '费用费率',
      actions: [
        IconButton(
          tooltip: '新增费率',
          onPressed: () => _edit(),
          icon: const Icon(LucideIcons.plus),
        ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                AiInfoCard(
                  title: '按百万 token 计价',
                  body: '未配置费率的请求仍统计 Token 和请求次数，但费用保持未知，不计入费用上限。',
                  icon: Icons.info_outline,
                ),
                const SizedBox(height: 12),
                if (rates.isEmpty)
                  Text(
                    '还没有费率。点右上角 + 添加。',
                    style: TextStyle(color: palette.muted, fontSize: 13),
                  )
                else
                  for (final rate in rates) ...[
                    SettingsGroupCard(
                      showDividers: false,
                      children: [
                        SettingsRow(
                          icon: Icons.payments_outlined,
                          title: rate.label,
                          subtitle:
                              '${rate.providerId == null ? '全部提供商' : _providerLabel(rate.providerId!)} · '
                              '${rate.modelId ?? '全部模型'} · ${rate.currency}',
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '输入 ${_money(rate.inputPerMillionMicros)} / 输出 ${_money(rate.outputPerMillionMicros)}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: palette.muted,
                                ),
                              ),
                              IconButton(
                                tooltip: '编辑',
                                onPressed: () => _edit(rate),
                                icon: const Icon(LucideIcons.pencil, size: 17),
                              ),
                              IconButton(
                                tooltip: '删除',
                                onPressed: () => _delete(rate),
                                icon: const Icon(LucideIcons.trash, size: 17),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
    );
  }

  String _providerLabel(String id) => _settings.provider(id)?.label ?? id;

  static String _money(int micros) =>
      (micros / 1000000).toStringAsFixed(micros % 1000000 == 0 ? 0 : 2);
}

class _RateEditor extends StatefulWidget {
  const _RateEditor({required this.settings, this.initial});

  final AiSettingsStore settings;
  final AiRateProfile? initial;

  @override
  State<_RateEditor> createState() => _RateEditorState();
}

class _RateEditorState extends State<_RateEditor> {
  late final TextEditingController _label;
  late final TextEditingController _currency;
  late final TextEditingController _input;
  late final TextEditingController _output;
  late final TextEditingController _cache;
  late final TextEditingController _reasoning;
  String? _providerId;
  String? _modelId;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _label = TextEditingController(text: initial?.label ?? '');
    _currency = TextEditingController(text: initial?.currency ?? 'CNY');
    _input = TextEditingController(
      text: _initialRate(initial?.inputPerMillionMicros),
    );
    _output = TextEditingController(
      text: _initialRate(initial?.outputPerMillionMicros),
    );
    _cache = TextEditingController(
      text: _initialRate(initial?.cachePerMillionMicros),
    );
    _reasoning = TextEditingController(
      text: _initialRate(initial?.reasoningPerMillionMicros),
    );
    _providerId = initial?.providerId;
    _modelId = initial?.modelId;
  }

  static String _initialRate(int? micros) {
    if (micros == null || micros == 0) return '';
    return (micros / 1000000).toString();
  }

  @override
  void dispose() {
    _label.dispose();
    _currency.dispose();
    _input.dispose();
    _output.dispose();
    _cache.dispose();
    _reasoning.dispose();
    super.dispose();
  }

  int? _parseRate(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return 0;
    final value = double.tryParse(text);
    if (value == null || !value.isFinite || value < 0) return null;
    return (value * 1000000).round();
  }

  void _save() {
    final label = _label.text.trim();
    final currency = _currency.text.trim().toUpperCase();
    final input = _parseRate(_input);
    final output = _parseRate(_output);
    final cache = _parseRate(_cache);
    final reasoning = _parseRate(_reasoning);
    if (label.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    if (currency.length != 3) {
      setState(() => _error = '币种请填 3 位代码，例如 CNY');
      return;
    }
    if (input == null || output == null || cache == null || reasoning == null) {
      setState(() => _error = '费率必须是不小于 0 的数字，可留空表示 0');
      return;
    }
    final now = DateTime.now();
    Navigator.pop(
      context,
      AiRateProfile(
        id:
            widget.initial?.id ??
            'rate_${now.microsecondsSinceEpoch.toRadixString(36)}',
        label: label,
        currency: currency,
        inputPerMillionMicros: input,
        outputPerMillionMicros: output,
        cachePerMillionMicros: cache,
        reasoningPerMillionMicros: reasoning,
        updatedAt: now,
        providerId: _providerId,
        modelId: _modelId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final providers = widget.settings.providers;
    final provider = widget.settings.provider(_providerId);
    final models = provider?.models ?? const <String>[];
    return AlertDialog(
      backgroundColor: palette.surface,
      title: Text(widget.initial == null ? '新增费率' : '编辑费率'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: _providerId,
              decoration: const InputDecoration(labelText: '提供商'),
              items: [
                const DropdownMenuItem(value: null, child: Text('全部提供商')),
                for (final item in providers)
                  DropdownMenuItem(value: item.id, child: Text(item.label)),
              ],
              onChanged: (value) => setState(() {
                _providerId = value;
                _modelId = null;
              }),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: _modelId,
              decoration: const InputDecoration(labelText: '模型'),
              items: [
                const DropdownMenuItem(value: null, child: Text('全部模型')),
                for (final item in models)
                  DropdownMenuItem(value: item, child: Text(item)),
              ],
              onChanged: (value) => setState(() => _modelId = value),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _currency,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: '币种'),
            ),
            const SizedBox(height: 8),
            _rateField(_input, '输入价格 / 百万 token'),
            _rateField(_output, '输出价格 / 百万 token'),
            _rateField(_cache, '缓存命中价格 / 百万 token'),
            _rateField(_reasoning, '推理价格 / 百万 token（留空按输出价）'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Widget _rateField(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
    ),
  );
}
