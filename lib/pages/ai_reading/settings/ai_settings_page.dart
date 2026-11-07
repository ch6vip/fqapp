import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/ai_reading/ai_budget.dart';
import '../../../services/ai_reading/ai_client.dart';
import '../../../services/ai_reading/ai_probe_service.dart';
import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_credentials.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_prompt.dart';
import '../../../services/ai_reading/ai_request_foreground.dart';
import '../../../services/ai_reading/ai_settings.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';
import '../../library_backup_page.dart';
import 'ai_cache_manage_page.dart';
import 'ai_prompt_editor_page.dart';
import 'ai_provider_page.dart';
import 'ai_rate_page.dart';
import 'ai_settings_widgets.dart';
import 'ai_usage_page.dart';

/// Global AI reading settings: consent, provider, display, prompt, prefetch
/// and budget. Book-level overrides live in [AiBookSettingsPage].
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  static const _globalBookId = '__global__';

  final _settings = AiSettingsStore.instance;
  final _controller = AiReadingController.instance;
  final _credentials = AiCredentialStore.instance;

  AiBudgetSnapshot? _budget;
  bool _probing = false;
  AiModelCapability? _probeResult;
  double? _triggerRatio;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _controller.init();
      await _reloadBudget();
      final global = _settings.global;
      final profile = _settings.provider(global.providerId);
      final model = global.modelId;
      if (profile != null && model != null && model.trim().isNotEmpty) {
        final stored = _settings.capabilityFor(
          providerId: profile.id,
          modelId: model,
          mode: profile.outputMode,
          baseUrl: profile.baseUrl,
        );
        if (stored != null && mounted) setState(() => _probeResult = stored);
      }
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, 'AI 设置读取失败：$error');
    }
  }

  Future<void> _reloadBudget() async {
    try {
      final snapshot = await AiBudgetService.instance.snapshot(_globalBookId);
      if (!mounted) return;
      setState(() => _budget = snapshot);
    } catch (_) {
      // The summary is informative only; keep the page usable.
    }
  }

  Future<void> _saveGlobal(AiGlobalSettings next) async {
    try {
      await _settings.saveGlobal(next);
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '保存失败：$error');
    }
  }

  Future<void> _toggleEnabled(bool value) async {
    if (!value) {
      await _saveGlobal(_settings.global.copyWith(enabled: false));
      return;
    }
    if (!_settings.device.cloudConsent) {
      final profile = _settings.provider(_settings.global.providerId);
      final agreed = await showAiConsentDialog(
        context,
        host: profile?.host ?? '尚未配置的提供商',
        model: _settings.global.modelId,
      );
      if (!agreed) return;
      try {
        await _controller.setCloudConsent(true);
      } catch (error) {
        if (!mounted) return;
        aiShowSnack(context, '保存云端同意失败：$error');
        return;
      }
    }
    await AiRequestForeground.ensureNotificationPermission();
    await _saveGlobal(_settings.global.copyWith(enabled: true));
  }

  Future<void> _toggleConsent() async {
    if (_settings.device.cloudConsent) {
      final confirmed = await showSettingsConfirmDialog(
        context: context,
        title: '撤回云端正文传输同意？',
        message: '撤回后不会再发起新请求；已保存的校对结果仍可查看。',
        confirmLabel: '撤回同意',
        destructive: true,
      );
      if (!confirmed) return;
      try {
        await _controller.setCloudConsent(false);
      } catch (error) {
        if (!mounted) return;
        aiShowSnack(context, '撤回失败：$error');
      }
      return;
    }
    final profile = _settings.provider(_settings.global.providerId);
    final agreed = await showAiConsentDialog(
      context,
      host: profile?.host ?? '尚未配置的提供商',
      model: _settings.global.modelId,
    );
    if (!agreed) return;
    try {
      await _controller.setCloudConsent(true);
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '保存云端同意失败：$error');
    }
  }

  Future<void> _pickModel() async {
    final providers = _settings.providers;
    if (providers.isEmpty) {
      await _openProviders();
      return;
    }
    final global = _settings.global;
    final providerChoice = await showAiChoiceDialog(
      context,
      title: '选择提供商',
      message: '先选提供商，再选这个提供商下的模型。',
      options: [
        for (final profile in providers)
          (
            key: profile.id,
            label: profile.label,
            selected: global.providerId == profile.id,
          ),
      ],
    );
    if (providerChoice == null || !mounted) return;
    final profile = _settings.provider(providerChoice);
    if (profile == null) return;
    if (profile.models.isEmpty) {
      aiShowSnack(context, '该提供商还没有配置模型');
      return;
    }
    final modelChoice = await showAiChoiceDialog(
      context,
      title: '选择模型',
      message: profile.label,
      options: [
        for (final id in profile.models)
          (
            key: id,
            label: id,
            selected: global.providerId == profile.id && global.modelId == id,
          ),
      ],
    );
    if (modelChoice == null) return;
    await _saveGlobal(
      _settings.global.copyWith(providerId: profile.id, modelId: modelChoice),
    );
    if (mounted) setState(() => _probeResult = null);
  }

  Future<void> _openProviders() async {
    await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const AiProviderPage()));
    if (!mounted) return;
    final global = _settings.global;
    var profile = _settings.provider(global.providerId);
    profile ??= _settings.providers.isEmpty ? null : _settings.providers.first;
    if (profile != null) {
      final model = profile.models.contains(global.modelId)
          ? global.modelId
          : (profile.models.isEmpty ? null : profile.models.first);
      if (global.providerId != profile.id || global.modelId != model) {
        await _saveGlobal(
          global.copyWith(providerId: profile.id, modelId: model),
        );
      }
    }
    await _reloadBudget();
    if (mounted) setState(() => _probeResult = null);
  }

  Future<AiModelCapability> _probeWithConfirmation(
    AiProviderProfile profile,
    String apiKey,
    String model,
    AiOutputMode outputMode,
  ) async {
    Future<AiModelCapability> attempt({bool confirmedOverBudget = false}) =>
        AiProbeService.instance.probe(
          profile: profile,
          apiKey: apiKey,
          model: model,
          outputMode: outputMode,
          timeout: Duration(seconds: _settings.global.requestTimeoutSeconds),
          confirmedOverBudget: confirmedOverBudget,
        );
    try {
      return await attempt();
    } on AiNetworkException catch (error) {
      if (error.code != 'BUDGET_CONFIRM' || !mounted) rethrow;
      final confirmed = await showAiBudgetDialog(context, error.message);
      if (!confirmed) {
        throw const AiNetworkException('BUDGET_CANCELLED', '已取消本次连接测试');
      }
      return attempt(confirmedOverBudget: true);
    }
  }

  Future<void> _testConnection() async {
    final global = _settings.global;
    final profile = _settings.provider(global.providerId);
    if (profile == null) {
      aiShowSnack(context, '请先配置提供商');
      return;
    }
    final model = global.modelId;
    if (model == null || model.trim().isEmpty) {
      aiShowSnack(context, '请先为提供商选择模型');
      return;
    }
    final apiKey = await _credentials.read(profile.credentialRef);
    if (apiKey == null) {
      if (!mounted) return;
      aiShowSnack(context, '请先填写 API Key');
      return;
    }
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    try {
      final capability = await _probeWithConfirmation(
        profile,
        apiKey,
        model,
        profile.outputMode,
      );
      await _settings.saveCapability(capability);
      if (!mounted) return;
      setState(() => _probeResult = capability);
      aiShowSnack(
        context,
        capability.ok ? '连接通过' : '连接失败：${capability.detail ?? '未知原因'}',
      );
      await _reloadBudget();
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '测试连接失败：$error');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _editPrompt() async {
    final global = _settings.global;
    final current = global.behaviorPrompt ?? kAiDefaultBehaviorPrompt;
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AiPromptEditorPage(
          title: '编辑全局提示词',
          hint: '留空表示使用内置提示词',
          initial: current,
          allowEmpty: true,
        ),
      ),
    );
    if (text == null || !mounted) return;
    final trimmed = text.trim();
    final next = trimmed.isEmpty || trimmed == kAiDefaultBehaviorPrompt.trim()
        ? null
        : text;
    await _saveGlobal(global.copyWith(behaviorPrompt: next));
  }

  double _ratio(num used, num limit) => limit <= 0 ? 0 : used / limit;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _settings,
      builder: (context, _) => SettingsScaffold(
        title: 'AI 阅读优化',
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (!_settings.isAvailable) ...[
              AiInfoCard(
                title: 'AI 设置存储不可用',
                body: _settings.status ?? '加密设置箱未能打开，修改将无法保存。',
                tone: AiStatusTone.warn,
                icon: Icons.warning_amber_outlined,
              ),
              const SizedBox(height: 12),
            ],
            GestureDetector(
              onLongPress: _showDeviceToggle,
              child: _budgetSummaryCard(context),
            ),
            const SizedBox(height: 16),
            const SettingsSectionHeader(title: '提供商与模型'),
            const SizedBox(height: 8),
            _cloudCard(context),
            const SizedBox(height: 16),
            const SettingsSectionHeader(title: '显示'),
            const SizedBox(height: 8),
            _displayCard(context),
            const SizedBox(height: 16),
            const SettingsSectionHeader(title: '校对行为'),
            const SizedBox(height: 8),
            _promptCard(context),
            const SizedBox(height: 16),
            const SettingsSectionHeader(title: '预校对'),
            const SizedBox(height: 8),
            _prefetchCard(context),
            const SizedBox(height: 16),
            const SettingsSectionHeader(title: '预算与用量'),
            const SizedBox(height: 8),
            _budgetCard(context),
            const SizedBox(height: 16),
            const SettingsSectionHeader(title: '高级'),
            const SizedBox(height: 8),
            _advancedCard(context),
          ],
        ),
      ),
    );
  }

  Widget _budgetSummaryCard(BuildContext context) {
    final palette = HomePalette.of(context);
    final global = _settings.global;
    final profile = _settings.provider(global.providerId);
    final daily = _budget?.daily;
    final tokens = daily?.tokenSum ?? 0;
    final requests = daily?.totalRequestCount ?? 0;
    final currency = daily?.currency ?? global.costCurrency;
    final tokenRatio = _ratio(tokens, global.dailyTokenLimit);
    final requestRatio = _ratio(requests, global.dailyRequestLimit);
    final costRatio = global.dailyCostLimit == null
        ? 0.0
        : _ratio((daily?.costMicros ?? 0) / 1000000, global.dailyCostLimit!);
    final ratio = math.max(tokenRatio, math.max(requestRatio, costRatio));
    final cost = aiFormatCostMicros(daily?.costMicros ?? 0, currency);
    final model = global.modelId?.trim();
    final status = profile == null
        ? '未配置'
        : _probeResult?.ok == true
        ? '已连接'
        : '已配置';
    final subtitle = profile == null
        ? '尚未配置提供商'
        : '${profile.label}${model == null || model.isEmpty ? '' : '，$model'}，$status';
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: palette.soft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  LucideIcons.sparkles,
                  size: 22,
                  color: palette.accentText,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI 阅读优化',
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
              SettingsSwitch(
                value: global.enabled,
                onChanged: _toggleEnabled,
                semanticLabel: 'AI 阅读优化总开关',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '今日 ${aiFormatTokens(tokens)} tokens，$cost 预估',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: palette.muted),
                ),
              ),
              Text(
                aiFormatPercent(ratio),
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 4,
              color: palette.ink,
              backgroundColor: palette.line,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cloudCard(BuildContext context) {
    final global = _settings.global;
    final profile = _settings.provider(global.providerId);
    final probe = _probeResult;
    final probeText = _probing
        ? '测试中'
        : probe == null
        ? '未测试'
        : probe.ok
        ? '通过'
        : '失败';
    return SettingsGroupCard(
      children: [
        SettingsRow(
          icon: Icons.dns_outlined,
          title: '提供商',
          value: profile?.label ?? '未配置',
          onTap: _openProviders,
        ),
        SettingsRow(
          icon: Icons.memory,
          title: '模型',
          value: global.modelId ?? '未选择',
          onTap: _pickModel,
        ),
        SettingsRow(
          icon: Icons.wifi_tethering,
          title: '测试连接',
          subtitle: probe != null && !probe.ok ? probe.detail : null,
          showChevron: false,
          trailing: _probing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : probe == null
              ? null
              : AiStatusPill(
                  label: probeText,
                  tone: probe.ok ? AiStatusTone.ok : AiStatusTone.error,
                ),
          onTap: _probing ? null : _testConnection,
        ),
      ],
    );
  }

  Widget _displayCard(BuildContext context) {
    final global = _settings.global;
    return SettingsGroupCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '显示模式',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: HomePalette.of(context).ink,
                ),
              ),
              const SizedBox(height: 10),
              AiModeSelector(
                value: global.displayMode,
                onChanged: (mode) =>
                    _saveGlobal(_settings.global.copyWith(displayMode: mode)),
              ),
            ],
          ),
        ),
        SettingsRow(
          icon: Icons.format_color_text,
          title: '修改标记',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: global.markStyle == 'off'
                  ? 'off'
                  : global.markStyle == 'solid'
                  ? 'solid'
                  : 'dotted',
              items: const [
                DropdownMenuItem(value: 'dotted', child: Text('低对比点线')),
                DropdownMenuItem(value: 'solid', child: Text('实线')),
                DropdownMenuItem(value: 'off', child: Text('关闭')),
              ],
              onChanged: (value) {
                if (value == null) return;
                _saveGlobal(_settings.global.copyWith(markStyle: value));
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _promptCard(BuildContext context) {
    final global = _settings.global;
    return SettingsGroupCard(
      children: [
        SettingsRow(
          icon: Icons.article_outlined,
          title: '提示词',
          value: global.behaviorPrompt == null ? '默认（保守校对）' : '自定义',
          onTap: _editPrompt,
        ),
      ],
    );
  }

  Widget _prefetchCard(BuildContext context) {
    final palette = HomePalette.of(context);
    final global = _settings.global;
    final ratio = _triggerRatio ?? global.prefetchTriggerRatio;
    return SettingsGroupCard(
      children: [
        SettingsRow(
          icon: Icons.download_for_offline_outlined,
          title: global.maxPrefetchChapters > 1 ? '预校对后续章节' : '预校对下一章',
          subtitle:
              '读到 ${aiFormatPercent(ratio)} 时自动校对'
              '${global.maxPrefetchChapters > 1 ? '后续 ${global.maxPrefetchChapters} 章' : '下一章'}',
          trailing: SettingsSwitch(
            value: global.prefetchEnabled,
            onChanged: (value) =>
                _saveGlobal(_settings.global.copyWith(prefetchEnabled: value)),
            semanticLabel: '预校对',
          ),
        ),
        SettingsRow(
          icon: Icons.format_list_numbered,
          title: '预校对范围',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: global.maxPrefetchChapters.clamp(1, 3),
              items: const [
                DropdownMenuItem(value: 1, child: Text('1 章')),
                DropdownMenuItem(value: 2, child: Text('2 章')),
                DropdownMenuItem(value: 3, child: Text('3 章')),
              ],
              onChanged: (value) {
                if (value == null) return;
                _saveGlobal(
                  _settings.global.copyWith(maxPrefetchChapters: value),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '触发点',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                  ),
                  Text(
                    aiFormatPercent(ratio),
                    style: TextStyle(fontSize: 13, color: palette.muted),
                  ),
                ],
              ),
              Slider(
                value: ratio.clamp(0.0, 0.9),
                min: 0,
                max: 0.9,
                divisions: 18,
                label: aiFormatPercent(ratio),
                onChanged: (value) => setState(() => _triggerRatio = value),
                onChangeEnd: (value) async {
                  await _saveGlobal(
                    _settings.global.copyWith(prefetchTriggerRatio: value),
                  );
                  if (!mounted) return;
                  setState(() => _triggerRatio = null);
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final tick in const ['0', '25', '50', '75', '90'])
                    Text(
                      tick,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _budgetCard(BuildContext context) {
    final global = _settings.global;
    final daily = _budget?.daily;
    final currency = daily?.currency ?? global.costCurrency;
    final dailyCostText = global.dailyCostLimit == null
        ? '未设上限'
        : aiFormatCostMicros(
            (global.dailyCostLimit! * 1000000).round(),
            currency,
          );
    final bookCostText = global.bookCostLimit == null
        ? '未设上限'
        : aiFormatCostMicros(
            (global.bookCostLimit! * 1000000).round(),
            currency,
          );
    return SettingsGroupCard(
      children: [
        SettingsRow(
          icon: Icons.insights_outlined,
          title: '今日用量',
          value:
              '${aiFormatTokens(daily?.tokenSum ?? 0)} tokens / '
              '${daily?.totalRequestCount ?? 0} 次',
          onTap: () async {
            await Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => const AiUsagePage(
                  bookId: _globalBookId,
                  title: '用量与费用',
                  includeBook: false,
                ),
              ),
            );
            if (!mounted) return;
            await _reloadBudget();
          },
        ),
        SettingsRow(
          icon: Icons.toll_outlined,
          title: '每日上限',
          value:
              '${aiFormatTokens(global.dailyTokenLimit)} tokens / '
              '${global.dailyRequestLimit} 次',
          onTap: _editDailyLimits,
        ),
        SettingsRow(
          icon: Icons.menu_book_outlined,
          title: '每本书上限',
          value:
              '${aiFormatTokens(global.bookTokenLimit)} tokens / '
              '${global.bookRequestLimit} 次',
          onTap: _editBookLimits,
        ),
        SettingsRow(
          icon: Icons.price_change_outlined,
          title: '费用费率',
          value: _settings.rates.isEmpty
              ? '未配置'
              : '${_settings.rates.length} 条',
          onTap: () async {
            await Navigator.of(
              context,
            ).push<void>(MaterialPageRoute(builder: (_) => const AiRatePage()));
            if (mounted) setState(() {});
          },
        ),
        SettingsRow(
          icon: Icons.payments_outlined,
          title: '费用上限',
          value: dailyCostText,
          onTap: () async {
            final result = await showAiCostDialog(
              context,
              title: '每日费用上限',
              label: '金额',
              currency: currency,
              initial: global.dailyCostLimit,
            );
            if (!result.saved) return;
            await _saveGlobal(
              _settings.global.copyWith(dailyCostLimit: result.value),
            );
          },
        ),
        SettingsRow(
          icon: Icons.account_balance_wallet_outlined,
          title: '每本书费用上限',
          value: bookCostText,
          onTap: () async {
            final result = await showAiCostDialog(
              context,
              title: '每本书费用上限',
              label: '金额',
              currency: currency,
              initial: global.bookCostLimit,
            );
            if (!result.saved) return;
            await _saveGlobal(
              _settings.global.copyWith(bookCostLimit: result.value),
            );
          },
        ),
      ],
    );
  }

  Future<void> _editDailyLimits() async {
    final global = _settings.global;
    final result = await showAiLimitDialog(
      context,
      title: '每日上限',
      tokenInitial: global.dailyTokenLimit,
      requestInitial: global.dailyRequestLimit,
      tokenLabel: '每日 Token 上限',
      requestLabel: '每日请求次数上限',
    );
    if (result == null || !mounted) return;
    await _saveGlobal(
      _settings.global.copyWith(
        dailyTokenLimit: result.tokens,
        dailyRequestLimit: result.requests,
      ),
    );
  }

  Future<void> _editBookLimits() async {
    final global = _settings.global;
    final result = await showAiLimitDialog(
      context,
      title: '每本书上限',
      tokenInitial: global.bookTokenLimit,
      requestInitial: global.bookRequestLimit,
      tokenLabel: '每本书 Token 上限',
      requestLabel: '每本书请求次数上限',
    );
    if (result == null || !mounted) return;
    await _saveGlobal(
      _settings.global.copyWith(
        bookTokenLimit: result.tokens,
        bookRequestLimit: result.requests,
      ),
    );
  }

  Widget _advancedCard(BuildContext context) {
    final consented = _settings.device.cloudConsent;
    return SettingsGroupCard(
      children: [
        SettingsRow(
          icon: Icons.cloud_outlined,
          title: '云端正文传输',
          subtitle: '隐私同意，不是日常开关',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                consented ? '已同意' : '未同意',
                style: TextStyle(
                  fontSize: 13,
                  color: HomePalette.of(context).muted,
                ),
              ),
              TextButton(
                onPressed: _toggleConsent,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(consented ? '撤回' : '去同意'),
              ),
            ],
          ),
        ),
        SettingsRow(
          icon: Icons.inventory_2_outlined,
          title: 'AI 数据备份',
          value: '包含',
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const LibraryBackupPage()),
          ),
        ),
        SettingsRow(
          icon: Icons.delete_sweep_outlined,
          title: '管理 AI 缓存',
          subtitle: '按书或按章清理正式校对结果',
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const AiCacheManagePage()),
          ),
        ),
      ],
    );
  }

  Future<void> _showDeviceToggle() async {
    var disabled = _settings.device.deviceDisabled;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('本机停用 AI 请求'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('排障用。打开后所有书都不再发请求；缓存和反馈保留。'),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('本机停用'),
                value: disabled,
                onChanged: (value) => setDialogState(() => disabled = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (disabled) _controller.cancelPrefetch();
                await _settings.saveDevice(
                  _settings.device.copyWith(deviceDisabled: disabled),
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) setState(() {});
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
