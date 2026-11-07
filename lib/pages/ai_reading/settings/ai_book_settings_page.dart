import 'package:flutter/material.dart';

import '../../../models/media_item.dart';
import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_feedback.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_prompt.dart';
import '../../../services/ai_reading/ai_settings.dart';
import '../../../services/ai_reading/ai_store.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';
import '../feedback/ai_feedback_manage_page.dart';
import 'ai_local_rebind_page.dart';
import 'ai_prompt_candidate_page.dart';
import 'ai_prompt_editor_page.dart';
import 'ai_settings_page.dart';
import 'ai_settings_widgets.dart';
import 'ai_usage_page.dart';
import 'ai_trial_page.dart';

/// Per-book AI settings. Every field can stay inherited from global or write a
/// book-level override; the page never copies global values into an override
/// unless the user explicitly chooses one.
class AiBookSettingsPage extends StatefulWidget {
  const AiBookSettingsPage({
    super.key,
    required this.bookId,
    required this.title,
    this.chapters,
  });

  final String bookId;
  final String title;

  /// Optional directory for future chapter pickers; not required by this page.
  final List<Chapter>? chapters;

  @override
  State<AiBookSettingsPage> createState() => _AiBookSettingsPageState();
}

class _AiBookSettingsPageState extends State<AiBookSettingsPage> {
  final _settings = AiSettingsStore.instance;

  int _activeCases = 0;
  int _activeProtections = 0;
  int _pendingBindings = 0;
  bool _statsLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      await AiReadingController.instance.init();
      final aggregates = await AiFeedbackService.instance.aggregatesForBook(
        widget.bookId,
      );
      var activeCases = 0;
      var activeProtections = 0;
      for (final aggregate in aggregates) {
        activeCases += aggregate.activeCases.length;
        activeProtections += aggregate.activeProtections.length;
      }
      var bindings = 0;
      if (widget.bookId.startsWith('local_')) {
        final rows = await AiStore.instance.pendingBindings();
        bindings = rows.length;
      }
      if (!mounted) return;
      setState(() {
        _activeCases = activeCases;
        _activeProtections = activeProtections;
        _pendingBindings = bindings;
        _statsLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statsLoading = false;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '保存失败：$error');
    }
  }

  Future<void> _pickEnabled() async {
    final effective = _settings.resolve(widget.bookId);
    final global = _settings.global;
    final choice = await showAiChoiceDialog(
      context,
      title: '主开关',
      message: '继承则跟随全局开关；本书覆写只影响这本书。',
      options: [
        (
          key: 'inherit',
          label: '继承全局（当前${global.enabled ? '开' : '关'}）',
          selected: effective.sources['enabled'] != 'book',
        ),
        (
          key: 'on',
          label: '本书强制开启',
          selected: effective.sources['enabled'] == 'book' && effective.enabled,
        ),
        (
          key: 'off',
          label: '本书关闭',
          selected:
              effective.sources['enabled'] == 'book' && !effective.enabled,
        ),
      ],
    );
    if (choice == null || !mounted) return;
    if (choice == 'on' && !_settings.device.cloudConsent) {
      final profile = _settings.provider(_settings.global.providerId);
      final agreed = await showAiConsentDialog(
        context,
        host: profile?.host ?? '尚未配置的提供商',
        model: _settings.global.modelId,
      );
      if (!agreed || !mounted) return;
      await AiReadingController.instance.setCloudConsent(true);
    }
    await _run(() async {
      if (choice == 'inherit') {
        await _settings.clearBookOverride(widget.bookId, 'enabled');
      } else {
        await _settings.setBookOverride(
          widget.bookId,
          'enabled',
          choice == 'on',
        );
      }
    });
  }

  Future<void> _pickDisplayMode() async {
    final effective = _settings.resolve(widget.bookId);
    final choice = await showAiChoiceDialog(
      context,
      title: '显示模式',
      options: [
        (
          key: 'inherit',
          label: '继承全局',
          selected: effective.sources['displayMode'] != 'book',
        ),
        for (final mode in AiDisplayMode.values)
          (
            key: mode.name,
            label: _modeLabel(mode),
            selected:
                effective.sources['displayMode'] == 'book' &&
                effective.displayMode == mode,
          ),
      ],
    );
    if (choice == null) return;
    await _run(() async {
      if (choice == 'inherit') {
        await _settings.clearBookOverride(widget.bookId, 'displayMode');
      } else {
        await _settings.setBookOverride(widget.bookId, 'displayMode', choice);
      }
    });
  }

  Future<void> _pickProvider() async {
    final settings = _settings;
    final effective = settings.resolve(widget.bookId);
    final providers = settings.providers;
    final globalProvider = settings.provider(settings.global.providerId);
    final choice = await showAiChoiceDialog(
      context,
      title: '提供商',
      message: '选择本书使用的提供商；模型在下一行选择。',
      options: [
        (
          key: '__inherit__',
          label: '继承全局（${globalProvider?.label ?? '未配置'}）',
          selected: effective.sources['providerId'] != 'book',
        ),
        for (final profile in providers)
          (
            key: profile.id,
            label: profile.label,
            selected:
                effective.sources['providerId'] == 'book' &&
                effective.providerId == profile.id,
          ),
      ],
    );
    if (choice == null) return;
    if (choice == '__inherit__') {
      await _run(() async {
        await settings.clearBookOverride(widget.bookId, 'providerId');
        await settings.clearBookOverride(widget.bookId, 'modelId');
      });
      return;
    }
    final profile = settings.provider(choice);
    if (profile == null) {
      if (!mounted) return;
      aiShowSnack(context, '提供商已不存在，请重新选择');
      return;
    }
    if (profile.models.isEmpty) {
      if (!mounted) return;
      aiShowSnack(context, '该提供商还没有配置模型');
      return;
    }
    final currentModel = effective.sources['modelId'] == 'book'
        ? effective.modelId
        : null;
    final nextModel =
        currentModel != null && profile.models.contains(currentModel)
        ? currentModel
        : profile.models.first;
    await _run(() async {
      await settings.setBookOverride(widget.bookId, 'providerId', profile.id);
      await settings.setBookOverride(widget.bookId, 'modelId', nextModel);
    });
  }

  Future<void> _pickModel() async {
    final settings = _settings;
    final effective = settings.resolve(widget.bookId);
    final profile = settings.provider(effective.providerId);
    if (profile == null) {
      aiShowSnack(context, '提供商已不存在，请重新选择');
      return;
    }
    final global = settings.global;
    final canInherit = effective.sources['providerId'] != 'book';
    final choice = await showAiChoiceDialog(
      context,
      title: '模型',
      message: profile.label,
      options: [
        if (canInherit)
          (
            key: '__inherit__',
            label: '继承全局（${global.modelId ?? '未选择'}）',
            selected: effective.sources['modelId'] != 'book',
          ),
        for (final id in profile.models)
          (
            key: id,
            label: id,
            selected:
                effective.sources['modelId'] == 'book' &&
                effective.modelId == id,
          ),
      ],
    );
    if (choice == null) return;
    await _run(() async {
      if (choice == '__inherit__') {
        await settings.clearBookOverride(widget.bookId, 'modelId');
      } else {
        await settings.setBookOverride(widget.bookId, 'modelId', choice);
      }
    });
  }

  Future<void> _promptActions() async {
    final resolved = _settings.resolvedPrompt(widget.bookId);
    final choice = await showAiChoiceDialog(
      context,
      title: '本书提示词',
      message: '当前来源：${aiSourceLabel(resolved.source)}。',
      options: [
        (key: 'edit', label: '编辑本书提示词', selected: false),
        (key: 'inherit', label: '恢复继承全局', selected: false),
        (key: 'factory', label: '恢复出厂提示词（写入本书）', selected: false),
      ],
    );
    if (choice == null) return;
    if (!mounted) return;
    switch (choice) {
      case 'edit':
        final text = await Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => AiPromptEditorPage(
              title: '编辑本书提示词',
              hint: '写入本书覆写，不影响其他书',
              initial: resolved.text,
            ),
          ),
        );
        if (text == null || !mounted) return;
        await _run(
          () =>
              _settings.setBookOverride(widget.bookId, 'behaviorPrompt', text),
        );
        return;
      case 'inherit':
        await _run(
          () => _settings.clearBookOverride(widget.bookId, 'behaviorPrompt'),
        );
        return;
      case 'factory':
        await _run(
          () => _settings.setBookOverride(
            widget.bookId,
            'behaviorPrompt',
            kAiDefaultBehaviorPrompt,
          ),
        );
        return;
    }
  }

  Future<void> _editPrefetch() async {
    final palette = HomePalette.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            final effective = _settings.resolve(widget.bookId);
            return Container(
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(22),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '预校对',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: palette.ink,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: () => Navigator.pop(sheetContext),
                            icon: Icon(Icons.close, color: palette.muted),
                          ),
                        ],
                      ),
                      SettingsGroupCard(
                        children: [
                          SettingsRow(
                            title: '开启预校对',
                            trailing: SettingsSwitch(
                              value: effective.prefetchEnabled,
                              semanticLabel: '开启预校对',
                              onChanged: (value) async {
                                await _run(
                                  () => _settings.setBookOverride(
                                    widget.bookId,
                                    'prefetchEnabled',
                                    value,
                                  ),
                                );
                                setSheet(() {});
                              },
                            ),
                          ),
                          SettingsRow(
                            title: '范围',
                            trailing: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: effective.maxPrefetchChapters.clamp(
                                  1,
                                  3,
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 1,
                                    child: Text('1 章'),
                                  ),
                                  DropdownMenuItem(
                                    value: 2,
                                    child: Text('2 章'),
                                  ),
                                  DropdownMenuItem(
                                    value: 3,
                                    child: Text('3 章'),
                                  ),
                                ],
                                onChanged: (value) async {
                                  if (value == null) return;
                                  await _run(
                                    () => _settings.setBookOverride(
                                      widget.bookId,
                                      'maxPrefetchChapters',
                                      value,
                                    ),
                                  );
                                  setSheet(() {});
                                },
                              ),
                            ),
                          ),
                          SettingsRow(
                            title: '触发点',
                            trailing: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: (effective.prefetchTriggerRatio * 100)
                                    .round()
                                    .clamp(0, 90),
                                items: [
                                  for (final percent in const [
                                    0,
                                    25,
                                    50,
                                    75,
                                    90,
                                  ])
                                    DropdownMenuItem(
                                      value: percent,
                                      child: Text('$percent%'),
                                    ),
                                ],
                                onChanged: (value) async {
                                  if (value == null) return;
                                  await _run(
                                    () => _settings.setBookOverride(
                                      widget.bookId,
                                      'prefetchTriggerRatio',
                                      value / 100,
                                    ),
                                  );
                                  setSheet(() {});
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      TextButton(
                        onPressed: () async {
                          await _run(() async {
                            await _settings.clearBookOverride(
                              widget.bookId,
                              'prefetchEnabled',
                            );
                            await _settings.clearBookOverride(
                              widget.bookId,
                              'maxPrefetchChapters',
                            );
                            await _settings.clearBookOverride(
                              widget.bookId,
                              'prefetchTriggerRatio',
                            );
                          });
                          setSheet(() {});
                        },
                        child: const Text('恢复继承全局'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return AnimatedBuilder(
      animation: _settings,
      builder: (context, _) {
        final effective = _settings.resolve(widget.bookId);
        final sources = effective.sources;
        final resolvedPrompt = _settings.resolvedPrompt(widget.bookId);
        final prefetch = effective.prefetchEnabled
            ? '${effective.maxPrefetchChapters} 章 / '
                  '${aiFormatPercent(effective.prefetchTriggerRatio)}'
            : '已关闭';
        return SettingsScaffold(
          title: '本书 AI 阅读优化',
          actions: [
            IconButton(
              tooltip: '全局 AI 阅读优化',
              icon: const Icon(Icons.tune_outlined),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => const AiSettingsPage()),
              ),
            ),
          ],
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: palette.line, width: 0.6),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: palette.soft,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.menu_book_outlined,
                        size: 21,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: palette.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${effective.enabled ? '开启' : '关闭'}，'
                            '${_modeLabel(effective.displayMode)}',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: palette.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SettingsSectionHeader(title: '本书设置'),
              const SizedBox(height: 8),
              SettingsGroupCard(
                children: [
                  SettingsRow(
                    icon: Icons.power_settings_new,
                    title: '主开关',
                    subtitle: effective.enabled ? '开' : '关',
                    trailing: aiSourceTrailing(context, sources['enabled']),
                    onTap: _pickEnabled,
                  ),
                  SettingsRow(
                    icon: Icons.visibility_outlined,
                    title: '显示模式',
                    subtitle: _modeLabel(effective.displayMode),
                    trailing: aiSourceTrailing(context, sources['displayMode']),
                    onTap: _pickDisplayMode,
                  ),
                  SettingsRow(
                    icon: Icons.dns_outlined,
                    title: '提供商',
                    subtitle:
                        _settings.provider(effective.providerId)?.label ??
                        '未配置',
                    trailing: aiSourceTrailing(context, sources['providerId']),
                    onTap: _pickProvider,
                  ),
                  SettingsRow(
                    icon: Icons.memory,
                    title: '模型',
                    subtitle: effective.modelId ?? '未选择',
                    trailing: aiSourceTrailing(context, sources['modelId']),
                    onTap: _pickModel,
                  ),
                  SettingsRow(
                    icon: Icons.article_outlined,
                    title: '提示词',
                    subtitle: resolvedPrompt.source == 'builtin'
                        ? '默认（保守校对）'
                        : '本书自定义',
                    trailing: aiSourceTrailing(context, resolvedPrompt.source),
                    onTap: _promptActions,
                  ),
                  SettingsRow(
                    icon: Icons.download_for_offline_outlined,
                    title: '预校对',
                    subtitle: prefetch,
                    trailing: aiSourceTrailing(
                      context,
                      sources['prefetchEnabled'],
                    ),
                    onTap: _editPrefetch,
                  ),
                  SettingsRow(
                    icon: Icons.toll_outlined,
                    title: '预算',
                    value:
                        '${aiFormatTokens(_settings.global.bookTokenLimit)} tokens / '
                        '${_settings.global.bookRequestLimit} 次',
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => AiUsagePage(
                          bookId: widget.bookId,
                          title: widget.title,
                          includeBook: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const SettingsSectionHeader(title: '本书反馈'),
              const SizedBox(height: 8),
              SettingsGroupCard(
                children: [
                  SettingsRow(
                    icon: Icons.record_voice_over_outlined,
                    title: '校对反馈',
                    value: _statsLoading
                        ? '统计中'
                        : '$_activeCases 条，$_activeProtections 条保护',
                    onTap: () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => AiFeedbackManagePage(
                            bookId: widget.bookId,
                            bookTitle: widget.title,
                          ),
                        ),
                      );
                      if (!mounted) return;
                      await _loadStats();
                    },
                  ),
                  SettingsRow(
                    icon: Icons.science_outlined,
                    title: '提示词候选',
                    value: '查看',
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => AiPromptCandidatePage(
                          bookId: widget.bookId,
                          title: widget.title,
                        ),
                      ),
                    ),
                  ),
                  SettingsRow(
                    icon: Icons.fact_check_outlined,
                    title: '试验结果',
                    value: '查看',
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => AiTrialPage(
                          bookId: widget.bookId,
                          title: widget.title,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (widget.bookId.startsWith('local_')) ...[
                const SizedBox(height: 16),
                const SettingsSectionHeader(title: '本地书'),
                const SizedBox(height: 8),
                SettingsGroupCard(
                  children: [
                    SettingsRow(
                      icon: Icons.link_outlined,
                      title: '本地书待绑定',
                      value: _statsLoading ? '检查中' : '$_pendingBindings 条',
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => AiLocalRebindPage(
                            bookId: widget.bookId,
                            title: widget.title,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _modeLabel(AiDisplayMode mode) => switch (mode) {
    AiDisplayMode.original => '原文',
    AiDisplayMode.customOnly => '仅自定义替换',
    AiDisplayMode.aiOptimized => 'AI 优化',
  };
}
