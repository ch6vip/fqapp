import 'dart:convert';

import 'ai_models.dart';
import 'ai_settings.dart';
import 'ai_store.dart';

class AiBudgetDecision {
  const AiBudgetDecision({
    required this.allowed,
    this.needsConfirmation = false,
    this.reason,
    this.usageRatio = 0,
  });

  final bool allowed;
  final bool needsConfirmation;
  final String? reason;
  final double usageRatio;
}

class AiBudgetSnapshot {
  const AiBudgetSnapshot({
    required this.day,
    required this.daily,
    required this.book,
    required this.settings,
  });

  final String day;
  final AiBudgetProjection daily;
  final AiBudgetProjection book;
  final AiEffectiveSettings settings;

  double get dailyTokenRatio => settings.dailyTokenLimit <= 0
      ? 0
      : daily.tokenSum / settings.dailyTokenLimit;
  double get bookTokenRatio => settings.bookTokenLimit <= 0
      ? 0
      : book.tokenSum / settings.bookTokenLimit;
  double get dailyRequestRatio => settings.dailyRequestLimit <= 0
      ? 0
      : daily.requestCount / settings.dailyRequestLimit;
  double get bookRequestRatio => settings.bookRequestLimit <= 0
      ? 0
      : book.requestCount / settings.bookRequestLimit;
}

class AiBudgetService {
  static const _globalBookId = '__global__';

  AiBudgetService({AiStore? store, AiSettingsStore? settings})
    : _store = store ?? AiStore.instance,
      _settings = settings ?? AiSettingsStore.instance;

  static final instance = AiBudgetService();
  final AiStore _store;
  final AiSettingsStore _settings;

  static String dayKey([DateTime? now]) {
    final date = (now ?? DateTime.now()).toLocal();
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  Future<AiBudgetDecision> check({
    required String bookId,
    required bool automatic,
    int? incomingTokens,
  }) async {
    final effective = _settings.resolve(bookId);
    if (!effective.enabled) {
      return const AiBudgetDecision(allowed: false, reason: 'AI 阅读优化未开启');
    }
    final day = dayKey();
    final daily =
        await _store.projection(day, null) ??
        AiBudgetProjection(
          bucketDay: day,
          bookId: null,
          requestCount: 0,
          taskCount: 0,
          tokenSum: 0,
          unknownUsageCount: 0,
          costMicros: 0,
          currency: effective.global.costCurrency,
          updatedAt: DateTime.now(),
        );
    final book =
        await _store.projection(day, bookId) ??
        AiBudgetProjection(
          bucketDay: day,
          bookId: bookId,
          requestCount: 0,
          taskCount: 0,
          tokenSum: 0,
          unknownUsageCount: 0,
          costMicros: 0,
          currency: effective.global.costCurrency,
          updatedAt: DateTime.now(),
        );
    final tokens = incomingTokens ?? 0;
    final checks = <String>[];
    if (daily.tokenSum + tokens > effective.dailyTokenLimit) {
      checks.add('今日 Token 已达上限');
    }
    if (book.tokenSum + tokens > effective.bookTokenLimit) {
      checks.add('本书今日 Token 已达上限');
    }
    if (daily.requestCount + 1 > effective.dailyRequestLimit) {
      checks.add('今日请求次数已达上限');
    }
    if (book.requestCount + 1 > effective.bookRequestLimit) {
      checks.add('本书今日请求次数已达上限');
    }
    final currency = effective.global.costCurrency;
    if (effective.dailyCostLimit != null &&
        daily.currency == currency &&
        daily.costMicros / 1000000 >= effective.dailyCostLimit!) {
      checks.add('今日费用已达上限');
    }
    if (effective.bookCostLimit != null &&
        book.currency == currency &&
        book.costMicros / 1000000 >= effective.bookCostLimit!) {
      checks.add('本书今日费用已达上限');
    }
    if (checks.isEmpty) {
      final ratio = [
        (daily.tokenSum + tokens) / effective.dailyTokenLimit,
        (book.tokenSum + tokens) / effective.bookTokenLimit,
        (daily.requestCount + 1) / effective.dailyRequestLimit,
        (book.requestCount + 1) / effective.bookRequestLimit,
      ].reduce((a, b) => a > b ? a : b);
      return AiBudgetDecision(allowed: true, usageRatio: ratio.clamp(0, 1));
    }
    final message = checks.join('；');
    if (automatic) {
      return AiBudgetDecision(
        allowed: false,
        usageRatio: 1,
        reason: '$message，自动预校对已暂停',
      );
    }
    return AiBudgetDecision(
      allowed: true,
      needsConfirmation: true,
      usageRatio: 1,
      reason: '$message，本次请求将超出预算',
    );
  }

  Future<void> recordRequest({
    required String bookId,
    required AiRequestRecord request,
    bool countTask = false,
  }) async {
    final day = dayKey(request.startedAt);
    final tokens = request.usage.knownTokenSum;
    final unknown = request.usage.status == AiUsageStatus.unknown ? 1 : 0;
    final cost = request.costMicros ?? 0;
    final currency = request.currency ?? 'CNY';
    await _update(
      day,
      null,
      request,
      tokens,
      unknown,
      cost,
      currency,
      countTask,
    );
    await _update(
      day,
      bookId,
      request,
      tokens,
      unknown,
      cost,
      currency,
      countTask,
    );
  }

  Future<void> _update(
    String day,
    String? bookId,
    AiRequestRecord request,
    int tokens,
    int unknown,
    int cost,
    String currency,
    bool countTask,
  ) async {
    final current =
        await _store.projection(day, bookId) ??
        AiBudgetProjection(
          bucketDay: day,
          bookId: bookId,
          requestCount: 0,
          taskCount: 0,
          tokenSum: 0,
          unknownUsageCount: 0,
          costMicros: 0,
          currency: currency,
          updatedAt: DateTime.now(),
        );
    final sameCurrency =
        request.currency == null || request.currency == currency;
    await _store.putProjection(
      current.copyWith(
        requestCount: current.requestCount + 1,
        taskCount: current.taskCount + (countTask ? 1 : 0),
        tokenSum: current.tokenSum + tokens,
        unknownUsageCount: current.unknownUsageCount + unknown,
        costMicros: current.costMicros + (sameCurrency ? cost : 0),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<AiBudgetSnapshot> snapshot(String bookId) async {
    final day = dayKey();
    final effective = _settings.resolve(bookId);
    final daily =
        await _store.projection(day, null) ??
        AiBudgetProjection(
          bucketDay: day,
          bookId: null,
          requestCount: 0,
          taskCount: 0,
          tokenSum: 0,
          unknownUsageCount: 0,
          costMicros: 0,
          currency: effective.global.costCurrency,
          updatedAt: DateTime.now(),
        );
    final book =
        await _store.projection(day, bookId) ??
        AiBudgetProjection(
          bucketDay: day,
          bookId: bookId,
          requestCount: 0,
          taskCount: 0,
          tokenSum: 0,
          unknownUsageCount: 0,
          costMicros: 0,
          currency: effective.global.costCurrency,
          updatedAt: DateTime.now(),
        );
    return AiBudgetSnapshot(
      day: day,
      daily: daily,
      book: book,
      settings: effective,
    );
  }

  Future<Map<String, dynamic>> usageSummary(String bookId) async {
    final requests = await _store.requests();
    final runs = await _store.runs();
    final isGlobal = bookId == _globalBookId;
    final bookRunIds = isGlobal
        ? runs.map((run) => run.runId).toSet()
        : runs
              .where((run) => run.bookId == bookId)
              .map((run) => run.runId)
              .toSet();
    final bookRequests = requests
        .where((request) => bookRunIds.contains(request.runId))
        .toList();
    var prompt = 0;
    var completion = 0;
    var cached = 0;
    var reasoning = 0;
    var unknown = 0;
    var known = 0;
    for (final request in bookRequests) {
      if (request.providerId.isEmpty) continue;
      prompt += request.usage.promptTokens ?? 0;
      completion += request.usage.completionTokens ?? 0;
      cached += request.usage.cachedTokens ?? 0;
      reasoning += request.usage.reasoningTokens ?? 0;
      if (request.usage.status == AiUsageStatus.unknown) {
        unknown++;
      } else {
        known++;
      }
    }
    final bookRuns = isGlobal
        ? runs
        : runs.where((run) => run.bookId == bookId).toList();
    return {
      'requestCount': bookRequests.length,
      'runCount': bookRuns.length,
      'successCount': bookRuns
          .where((r) => r.state == AiRunState.success)
          .length,
      'failureCount': bookRuns
          .where((r) => r.state == AiRunState.failed)
          .length,
      'promptTokens': prompt,
      'completionTokens': completion,
      'cachedTokens': cached,
      'reasoningTokens': reasoning,
      'knownUsageCount': known,
      'unknownUsageCount': unknown,
      'estimatedCostMicros': bookRequests.fold<int>(
        0,
        (sum, request) => sum + (request.costMicros ?? 0),
      ),
      'currency': bookRequests.isEmpty
          ? 'CNY'
          : (bookRequests.first.currency ?? 'CNY'),
    };
  }

  static String encodeKey(String day, String? bookId) =>
      jsonEncode([day, bookId]);
}
