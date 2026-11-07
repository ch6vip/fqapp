import 'package:flutter/material.dart';

import '../../../services/ai_reading/ai_budget.dart';
import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_store.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';
import 'ai_settings_widgets.dart';

/// Usage and estimated cost for the current day and one book. Requests come
/// from the local ledger; nothing here reads chapter text or API keys.
class AiUsagePage extends StatefulWidget {
  const AiUsagePage({
    super.key,
    required this.bookId,
    required this.title,
    this.includeBook = true,
  });

  final String bookId;
  final String title;

  /// The global entry point has no single book, so it hides the book section.
  final bool includeBook;

  @override
  State<AiUsagePage> createState() => _AiUsagePageState();
}

class _AiUsagePageState extends State<AiUsagePage> {
  AiBudgetSnapshot? _snapshot;
  Map<String, dynamic>? _summary;
  List<AiRequestRecord> _requests = const [];
  Map<String, AiRunKind> _runKinds = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AiReadingController.instance.init();
      final snapshot = await AiBudgetService.instance.snapshot(widget.bookId);
      final summary = await AiBudgetService.instance.usageSummary(
        widget.bookId,
      );
      final requests = await AiStore.instance.requests();
      final runs = await AiStore.instance.runs();
      final bookRunIds = widget.bookId == '__global__'
          ? null
          : {
              for (final run in runs)
                if (run.bookId == widget.bookId) run.runId,
            };
      final visibleRequests = bookRunIds == null
          ? requests
          : requests
                .where((request) => bookRunIds.contains(request.runId))
                .toList(growable: false);
      requests.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      visibleRequests.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _summary = summary;
        _requests = visibleRequests.take(20).toList(growable: false);
        _runKinds = {for (final run in runs) run.runId: run.kind};
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _clearLedger() async {
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '清理历史账本？',
      message: '只会删除请求记录、运行记录和用量聚合，不会删除正式校对缓存、反馈、保护或提示词。',
      confirmLabel: '清理账本',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await AiStore.instance.clearLedgers();
      await _load();
      if (mounted) aiShowSnack(context, '历史账本已清理');
    } catch (error) {
      if (mounted) aiShowSnack(context, '清理失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: widget.title,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorView()
          : _content(context),
    );
  }

  Widget _errorView() {
    final palette = HomePalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '用量读取失败',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: palette.muted,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final palette = HomePalette.of(context);
    final snapshot = _snapshot;
    final summary = _summary;
    final daily = snapshot?.daily;
    final book = snapshot?.book;
    final global = snapshot?.settings.global;
    final currency = daily?.currency ?? global?.costCurrency ?? 'CNY';
    final dailyTokens = daily?.tokenSum ?? 0;
    final dailyRequests = daily?.totalRequestCount ?? 0;
    final bookTokens = book?.tokenSum ?? 0;
    final bookRequests = book?.totalRequestCount ?? 0;
    final dailyTokenLimit = global?.dailyTokenLimit ?? 0;
    final bookTokenLimit = global?.bookTokenLimit ?? 0;
    final dailyRequestLimit = global?.dailyRequestLimit ?? 0;
    final bookRequestLimit = global?.bookRequestLimit ?? 0;
    final unknownUsage = daily?.unknownUsageCount ?? 0;
    final estimatedCost = summary?['estimatedCostMicros'] as int? ?? 0;
    final unknownRequests = summary?['unknownUsageCount'] as int? ?? 0;
    final costText = estimatedCost == 0 && unknownRequests > 0
        ? '未知'
        : unknownRequests > 0
        ? '${aiFormatCostMicros(estimatedCost, currency)}，另有 $unknownRequests 次未知'
        : aiFormatCostMicros(estimatedCost, currency);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _budgetCard(
          context,
          palette,
          daily: daily,
          book: book,
          currency: currency,
          global: global,
          dailyTokens: dailyTokens,
          dailyRequests: dailyRequests,
          bookTokens: bookTokens,
          bookRequests: bookRequests,
          dailyTokenLimit: dailyTokenLimit,
          bookTokenLimit: bookTokenLimit,
          dailyRequestLimit: dailyRequestLimit,
          bookRequestLimit: bookRequestLimit,
          unknownUsage: unknownUsage,
        ),
        const SizedBox(height: 16),
        const SettingsSectionHeader(title: '用量汇总'),
        const SizedBox(height: 8),
        SettingsGroupCard(
          children: [
            SettingsRow(
              icon: Icons.cloud_upload_outlined,
              title: 'API 请求',
              value: '${summary?['requestCount'] ?? 0} 次',
            ),
            SettingsRow(
              icon: Icons.task_alt,
              title: '校对任务',
              value: '${summary?['runCount'] ?? 0} 个',
            ),
            SettingsRow(
              icon: Icons.data_usage_outlined,
              title: 'Token',
              value: aiFormatTokens(
                (summary?['promptTokens'] as int? ?? 0) +
                    (summary?['completionTokens'] as int? ?? 0),
              ),
            ),
            SettingsRow(
              icon: Icons.help_outline,
              title: '未知用量',
              value: '${summary?['unknownUsageCount'] ?? 0} 次',
            ),
            SettingsRow(
              icon: Icons.payments_outlined,
              title: '预估费用',
              value: costText,
            ),
          ],
        ),
        const SizedBox(height: 16),
        const SettingsSectionHeader(title: '最近请求'),
        const SizedBox(height: 8),
        SettingsGroupCard(
          children: [
            if (_requests.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '还没有请求记录。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: palette.muted,
                  ),
                ),
              )
            else
              for (final request in _requests)
                SettingsRow(
                  title:
                      '${aiFormatDateTime(request.startedAt)}，'
                      '${_purposeLabel(request)}',
                  subtitle:
                      '${request.model.isEmpty ? '未知模型' : request.model}，'
                      '${request.usage.hasAnyKnown ? '${aiFormatTokens(request.usage.totalTokens ?? request.usage.knownTokenSum)} tokens' : '用量未知'}'
                      '，用时 ${_formatDuration(request.latencyMs)}'
                      '${request.errorCode == null ? '' : '，错误 ${request.errorCode}'}',
                ),
          ],
        ),
        const SizedBox(height: 16),
        SettingsGroupCard(
          children: [
            SettingsRow(
              icon: Icons.delete_sweep_outlined,
              title: '清理历史账本',
              onTap: _clearLedger,
            ),
          ],
        ),
      ],
    );
  }

  Widget _budgetCard(
    BuildContext context,
    HomePalette palette, {
    required AiBudgetProjection? daily,
    required AiBudgetProjection? book,
    required String currency,
    required AiGlobalSettings? global,
    required int dailyTokens,
    required int dailyRequests,
    required int bookTokens,
    required int bookRequests,
    required int dailyTokenLimit,
    required int bookTokenLimit,
    required int dailyRequestLimit,
    required int bookRequestLimit,
    required int unknownUsage,
  }) {
    final dailyCost = daily?.costMicros ?? 0;
    final bookCost = book?.costMicros ?? 0;
    return SettingsGroupCard(
      showDividers: false,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
          child: Text(
            '今日',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: palette.ink,
            ),
          ),
        ),
        _progressBlock(
          palette,
          label: 'tokens',
          used: aiFormatTokens(dailyTokens),
          limit: aiFormatTokens(dailyTokenLimit),
          ratio: dailyTokenLimit <= 0 ? 0 : dailyTokens / dailyTokenLimit,
        ),
        _progressBlock(
          palette,
          label: '请求',
          used: '$dailyRequests',
          limit: '$dailyRequestLimit',
          ratio: dailyRequestLimit <= 0 ? 0 : dailyRequests / dailyRequestLimit,
        ),
        _costBlock(
          palette,
          used: dailyCost,
          limit: global?.dailyCostLimit,
          currency: currency,
          unknown: unknownUsage > 0,
        ),
        Divider(height: 24, color: palette.line),
        if (widget.includeBook) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
            child: Text(
              '本书',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
          ),
          _progressBlock(
            palette,
            label: 'tokens',
            used: aiFormatTokens(bookTokens),
            limit: aiFormatTokens(bookTokenLimit),
            ratio: bookTokenLimit <= 0 ? 0 : bookTokens / bookTokenLimit,
          ),
          _progressBlock(
            palette,
            label: '请求',
            used: '$bookRequests',
            limit: '$bookRequestLimit',
            ratio: bookRequestLimit <= 0 ? 0 : bookRequests / bookRequestLimit,
          ),
          _costBlock(
            palette,
            used: bookCost,
            limit: global?.bookCostLimit,
            currency: currency,
            unknown: unknownUsage > 0,
          ),
        ],
        if (unknownUsage > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              '今日有 $unknownUsage 次请求未返回用量，费用可能更高。',
              style: TextStyle(fontSize: 12, height: 1.4, color: palette.muted),
            ),
          )
        else
          const SizedBox(height: 8),
      ],
    );
  }

  Widget _progressBlock(
    HomePalette palette, {
    required String label,
    required String used,
    required String limit,
    required double ratio,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: palette.ink),
                ),
              ),
              Text(
                '$used / $limit',
                style: TextStyle(fontSize: 12.5, color: palette.muted),
              ),
              const SizedBox(width: 8),
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
              minHeight: 6,
              color: palette.ink,
              backgroundColor: palette.line,
            ),
          ),
        ],
      ),
    );
  }

  Widget _costBlock(
    HomePalette palette, {
    required int used,
    required double? limit,
    required String currency,
    required bool unknown,
  }) {
    final usedText = unknown && used == 0
        ? '未知'
        : unknown
        ? '${aiFormatCostMicros(used, currency)}，部分未知'
        : aiFormatCostMicros(used, currency);
    final limitText = limit == null
        ? '未配置上限'
        : aiFormatCostMicros((limit * 1000000).round(), currency);
    final ratio = limit == null || limit <= 0 ? 0.0 : used / (limit * 1000000);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '预估费用',
                  style: TextStyle(fontSize: 13, color: palette.ink),
                ),
              ),
              Text(
                '$usedText / $limitText',
                style: TextStyle(fontSize: 12.5, color: palette.muted),
              ),
              if (limit != null) ...[
                const SizedBox(width: 8),
                Text(
                  aiFormatPercent(ratio),
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 6,
              color: palette.ink,
              backgroundColor: palette.line,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDuration(int milliseconds) {
    if (milliseconds < 1000) return '$milliseconds ms';
    if (milliseconds < 60000) {
      final seconds = milliseconds / 1000;
      return '${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)} 秒';
    }
    final minutes = milliseconds ~/ 60000;
    final seconds = (milliseconds % 60000) ~/ 1000;
    return seconds == 0 ? '$minutes 分' : '$minutes 分 $seconds 秒';
  }

  String _purposeLabel(AiRequestRecord request) {
    final kind = _runKinds[request.runId];
    if (kind != null) {
      return switch (kind) {
        AiRunKind.formalFirst => '正式校对',
        AiRunKind.formalRefresh => '重新校对',
        AiRunKind.formalPrefetch => '预校对',
        AiRunKind.trial => '提示词试验',
        AiRunKind.promptOptimize => '提示词优化',
        AiRunKind.probe => '连接测试',
        AiRunKind.recovered => '崩溃恢复',
      };
    }
    return switch (request.reason) {
      'first' => '正式校对',
      'content_repair' => '内容纠错',
      'crash_recovered' => '崩溃恢复（用量未知）',
      _ => 'API 请求',
    };
  }
}
