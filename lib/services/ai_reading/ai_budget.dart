import 'dart:async';
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
    this.reservation,
  });

  final bool allowed;
  final bool needsConfirmation;
  final String? reason;
  final double usageRatio;
  final AiBudgetReservation? reservation;
}

class AiBudgetReservation {
  const AiBudgetReservation({
    required this.day,
    required this.bookId,
    required this.displayCurrency,
  });

  final String day;
  final String bookId;
  final String displayCurrency;
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
  Future<void> _writeQueue = Future<void>.value();

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
    final displayCurrency = effective.global.costCurrency;
    final daily =
        await _store.projection(day, null) ??
        _emptyProjection(day, null, displayCurrency);
    final book =
        await _store.projection(day, bookId) ??
        _emptyProjection(day, bookId, displayCurrency);
    return _decide(
      effective: effective,
      daily: daily,
      book: book,
      automatic: automatic,
      incomingTokens: incomingTokens ?? 0,
      displayCurrency: displayCurrency,
    );
  }

  /// Atomically checks and reserves one HTTP request slot. The request count is
  /// committed before the network call, so concurrent chapters cannot both
  /// consume the last slot. Token/cost are settled with [settle] afterwards.
  Future<AiBudgetDecision> reserve({
    required String bookId,
    required bool automatic,
    required bool countTask,
    bool confirmedOverBudget = false,
  }) async {
    final effective = _settings.resolve(bookId);
    if (!effective.enabled) {
      return const AiBudgetDecision(allowed: false, reason: 'AI 阅读优化未开启');
    }
    final day = dayKey();
    final displayCurrency = effective.global.costCurrency;
    return _enqueue(() async {
      final daily =
          await _store.projection(day, null) ??
          _emptyProjection(day, null, displayCurrency);
      final book =
          await _store.projection(day, bookId) ??
          _emptyProjection(day, bookId, displayCurrency);
      final decision = _decide(
        effective: effective,
        daily: daily,
        book: book,
        automatic: automatic,
        incomingTokens: 0,
        displayCurrency: displayCurrency,
        confirmedOverBudget: confirmedOverBudget,
      );
      if (!decision.allowed || decision.needsConfirmation) return decision;
      final reservation = AiBudgetReservation(
        day: day,
        bookId: bookId,
        displayCurrency: displayCurrency,
      );
      await _store.putProjection(
        daily.copyWith(
          requestCount: daily.requestCount + 1,
          taskCount: daily.taskCount + (countTask ? 1 : 0),
          updatedAt: DateTime.now(),
        ),
      );
      await _store.putProjection(
        book.copyWith(
          requestCount: book.requestCount + 1,
          taskCount: book.taskCount + (countTask ? 1 : 0),
          updatedAt: DateTime.now(),
        ),
      );
      return AiBudgetDecision(
        allowed: true,
        usageRatio: decision.usageRatio,
        reservation: reservation,
      );
    });
  }

  /// Adds actual usage after a request. The request slot was already counted by
  /// [reserve], so this never increments [requestCount] or [taskCount].
  Future<void> settle({
    required AiBudgetReservation reservation,
    required AiRequestRecord request,
  }) async {
    final currency = request.currency ?? reservation.displayCurrency;
    await _apply(
      day: reservation.day,
      bookId: null,
      tokens: request.usage.knownTokenSum,
      unknown: request.usage.status == AiUsageStatus.unknown ? 1 : 0,
      cost: request.costMicros ?? 0,
      requestCurrency: currency,
      displayCurrency: reservation.displayCurrency,
      countRequest: false,
      addUsage: true,
      countTask: false,
    );
    await _apply(
      day: reservation.day,
      bookId: reservation.bookId,
      tokens: request.usage.knownTokenSum,
      unknown: request.usage.status == AiUsageStatus.unknown ? 1 : 0,
      cost: request.costMicros ?? 0,
      requestCurrency: currency,
      displayCurrency: reservation.displayCurrency,
      countRequest: false,
      addUsage: true,
      countTask: false,
    );
  }

  AiBudgetDecision _decide({
    required AiEffectiveSettings effective,
    required AiBudgetProjection daily,
    required AiBudgetProjection book,
    required bool automatic,
    required int incomingTokens,
    required String displayCurrency,
    bool confirmedOverBudget = false,
  }) {
    final checks = <String>[];
    if (daily.tokenSum + incomingTokens > effective.dailyTokenLimit) {
      checks.add('今日 Token 已达上限');
    }
    if (book.tokenSum + incomingTokens > effective.bookTokenLimit) {
      checks.add('本书今日 Token 已达上限');
    }
    if (daily.requestCount + 1 > effective.dailyRequestLimit) {
      checks.add('今日请求次数已达上限');
    }
    if (book.requestCount + 1 > effective.bookRequestLimit) {
      checks.add('本书今日请求次数已达上限');
    }
    if (effective.dailyCostLimit != null &&
        daily.costFor(displayCurrency) / 1000000 >= effective.dailyCostLimit!) {
      checks.add('今日费用已达上限');
    }
    if (effective.bookCostLimit != null &&
        book.costFor(displayCurrency) / 1000000 >= effective.bookCostLimit!) {
      checks.add('本书今日费用已达上限');
    }
    if (checks.isEmpty) {
      final ratio = [
        (daily.tokenSum + incomingTokens) / effective.dailyTokenLimit,
        (book.tokenSum + incomingTokens) / effective.bookTokenLimit,
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
    if (!confirmedOverBudget) {
      return AiBudgetDecision(
        allowed: true,
        needsConfirmation: true,
        usageRatio: 1,
        reason: '$message，本次请求将超出预算',
      );
    }
    return AiBudgetDecision(allowed: true, usageRatio: 1);
  }

  AiBudgetProjection _emptyProjection(
    String day,
    String? bookId,
    String currency,
  ) => AiBudgetProjection(
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

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _writeQueue;
    _writeQueue = () async {
      try {
        await previous;
      } catch (_) {
        // A failed earlier operation must not poison the queue.
      }
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    }();
    return completer.future;
  }

  Future<void> _apply({
    required String day,
    required String? bookId,
    required int tokens,
    required int unknown,
    required int cost,
    required String requestCurrency,
    required String displayCurrency,
    required bool countRequest,
    required bool addUsage,
    required bool countTask,
  }) {
    return _enqueue(() async {
      final current =
          await _store.projection(day, bookId) ??
          _emptyProjection(day, bookId, displayCurrency);
      final costs = <String, int>{...current.costsByCurrency};
      if (addUsage && cost != 0) {
        costs[requestCurrency] = (costs[requestCurrency] ?? 0) + cost;
      }
      await _store.putProjection(
        current.copyWith(
          requestCount: current.requestCount + (countRequest ? 1 : 0),
          taskCount: current.taskCount + (countTask ? 1 : 0),
          tokenSum: current.tokenSum + (addUsage ? tokens : 0),
          unknownUsageCount:
              current.unknownUsageCount + (addUsage ? unknown : 0),
          costMicros: costs[displayCurrency] ?? 0,
          currency: displayCurrency,
          costsByCurrency: Map.unmodifiable(costs),
          updatedAt: DateTime.now(),
        ),
      );
    });
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
    final currency = effective.global.costCurrency;
    AiBudgetProjection display(AiBudgetProjection projection) => projection
        .copyWith(currency: currency, costMicros: projection.costFor(currency));
    return AiBudgetSnapshot(
      day: day,
      daily: display(daily),
      book: display(book),
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
    final costsByCurrency = <String, int>{};
    for (final request in bookRequests) {
      if (request.costMicros == null) continue;
      final currency = request.currency ?? 'CNY';
      costsByCurrency[currency] =
          (costsByCurrency[currency] ?? 0) + request.costMicros!;
    }
    final currency = _settings.resolve(bookId).global.costCurrency;
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
      'estimatedCostMicros': costsByCurrency[currency] ?? 0,
      'estimatedCostsByCurrency': costsByCurrency,
      'currency': currency,
    };
  }

  static String encodeKey(String day, String? bookId) =>
      jsonEncode([day, bookId]);
}
