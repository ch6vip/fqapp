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
    this.code,
    this.usageRatio = 0,
    this.reservation,
  });

  final bool allowed;
  final bool needsConfirmation;
  final String? reason;
  final String? code;
  final double usageRatio;
  final AiBudgetReservation? reservation;
}

class AiBudgetReservation {
  const AiBudgetReservation({
    required this.day,
    required this.bookId,
    required this.displayCurrency,
    required this.countTask,
  });

  final String day;
  final String bookId;
  final String displayCurrency;

  /// Whether this reservation incremented the task counter. Retries share a
  /// task and must not decrement it when their reservation is released.
  final bool countTask;
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
  }) {
    return _enqueue(() async {
      // Re-read every gate inside the serialized queue. Consent can be revoked
      // while this task waits behind another budget write.
      final effective = _settings.resolve(bookId);
      if (!effective.enabled) {
        return const AiBudgetDecision(
          allowed: false,
          reason: 'AI 阅读优化未开启',
          code: 'DISABLED',
          usageRatio: 1,
        );
      }
      if (_settings.device.deviceDisabled) {
        return const AiBudgetDecision(
          allowed: false,
          reason: '本机已停用 AI 请求',
          code: 'DEVICE_DISABLED',
          usageRatio: 1,
        );
      }
      if (!_settings.device.cloudConsent) {
        return const AiBudgetDecision(
          allowed: false,
          reason: '还没有同意把章节正文发送给第三方',
          code: 'CONSENT_REQUIRED',
          usageRatio: 1,
        );
      }
      final day = dayKey();
      final displayCurrency = effective.global.costCurrency;
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
        countTask: countTask,
      );
      final nextDaily = daily.copyWith(
        requestCount: daily.requestCount + 1,
        taskCount: daily.taskCount + (countTask ? 1 : 0),
        updatedAt: DateTime.now(),
      );
      final nextBook = book.copyWith(
        requestCount: book.requestCount + 1,
        taskCount: book.taskCount + (countTask ? 1 : 0),
        updatedAt: DateTime.now(),
      );
      try {
        await _store.putProjection(nextDaily);
        await _store.putProjection(nextBook);
      } catch (_) {
        // Hive has no cross-key transaction. Never leave a half-reserved slot
        // behind when the second write fails.
        try {
          await _store.putProjection(daily);
        } catch (_) {}
        try {
          await _store.putProjection(book);
        } catch (_) {}
        return const AiBudgetDecision(
          allowed: false,
          reason: '预算写入失败，请重试',
          code: 'BUDGET_WRITE_FAILED',
          usageRatio: 1,
        );
      }
      return AiBudgetDecision(
        allowed: true,
        usageRatio: decision.usageRatio,
        reservation: reservation,
      );
    });
  }

  /// Returns a reservation whose HTTP call was cancelled before it was sent.
  Future<void> release(AiBudgetReservation reservation) {
    return _enqueue(() async {
      final daily =
          await _store.projection(reservation.day, null) ??
          _emptyProjection(reservation.day, null, reservation.displayCurrency);
      final book =
          await _store.projection(reservation.day, reservation.bookId) ??
          _emptyProjection(
            reservation.day,
            reservation.bookId,
            reservation.displayCurrency,
          );
      final nextDaily = daily.copyWith(
        requestCount: daily.requestCount > 0 ? daily.requestCount - 1 : 0,
        taskCount: reservation.countTask && daily.taskCount > 0
            ? daily.taskCount - 1
            : daily.taskCount,
        updatedAt: DateTime.now(),
      );
      final nextBook = book.copyWith(
        requestCount: book.requestCount > 0 ? book.requestCount - 1 : 0,
        taskCount: reservation.countTask && book.taskCount > 0
            ? book.taskCount - 1
            : book.taskCount,
        updatedAt: DateTime.now(),
      );
      try {
        await _store.putProjection(nextDaily);
        await _store.putProjection(nextBook);
      } catch (_) {
        try {
          await _store.putProjection(daily);
        } catch (_) {}
        try {
          await _store.putProjection(book);
        } catch (_) {}
        rethrow;
      }
    });
  }

  /// Adds actual usage after a request. The request slot was already counted by
  /// [reserve], so this never increments [requestCount] or [taskCount]. Global
  /// and per-book projections are updated in the same queue turn so a new
  /// reservation cannot observe one half of this settlement.
  Future<void> settle({
    required AiBudgetReservation reservation,
    required AiRequestRecord request,
  }) {
    final currency = request.currency ?? reservation.displayCurrency;
    return _enqueue(() async {
      final targets = <String?, AiBudgetProjection>{};
      try {
        for (final bookId in <String?>[null, reservation.bookId]) {
          final current =
              await _store.projection(reservation.day, bookId) ??
              _emptyProjection(
                reservation.day,
                bookId,
                reservation.displayCurrency,
              );
          targets[bookId] = current;
          final costs = <String, int>{...current.costsByCurrency};
          final cost = request.costMicros ?? 0;
          if (cost != 0) {
            costs[currency] = (costs[currency] ?? 0) + cost;
          }
          await _store.putProjection(
            current.copyWith(
              tokenSum: current.tokenSum + request.usage.knownTokenSum,
              unknownUsageCount:
                  current.unknownUsageCount +
                  (request.usage.status == AiUsageStatus.unknown ? 1 : 0),
              costMicros: costs[reservation.displayCurrency] ?? 0,
              currency: reservation.displayCurrency,
              costsByCurrency: Map.unmodifiable(costs),
              updatedAt: DateTime.now(),
            ),
          );
        }
      } catch (_) {
        // Best effort compensation; the request ledger remains authoritative.
        for (final entry in targets.entries) {
          try {
            await _store.putProjection(entry.value);
          } catch (_) {}
        }
        rethrow;
      }
    });
  }

  /// Monotonic restore of a usage projection. It shares the budget queue with
  /// [reserve] and [settle], so an in-flight request cannot be overwritten by
  /// an older backup snapshot.
  Future<void> mergeUsage(AiBudgetProjection incoming) {
    return _enqueue(() async {
      final current = await _store.projection(
        incoming.bucketDay,
        incoming.bookId,
      );
      final costs = <String, int>{...?current?.costsByCurrency};
      for (final entry in incoming.costsByCurrency.entries) {
        final previous = costs[entry.key] ?? 0;
        if (entry.value > previous) costs[entry.key] = entry.value;
      }
      final merged = current == null
          ? incoming.copyWith(costsByCurrency: Map.unmodifiable(costs))
          : incoming.copyWith(
              requestCount: incoming.requestCount > current.requestCount
                  ? incoming.requestCount
                  : current.requestCount,
              taskCount: incoming.taskCount > current.taskCount
                  ? incoming.taskCount
                  : current.taskCount,
              tokenSum: incoming.tokenSum > current.tokenSum
                  ? incoming.tokenSum
                  : current.tokenSum,
              unknownUsageCount:
                  incoming.unknownUsageCount > current.unknownUsageCount
                  ? incoming.unknownUsageCount
                  : current.unknownUsageCount,
              costsByCurrency: Map.unmodifiable(costs),
              currency: current.currency,
              costMicros: costs[current.currency] ?? 0,
            );
      await _store.putProjection(merged);
    });
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
    if (daily.tokenSum + incomingTokens >= effective.dailyTokenLimit) {
      checks.add('今日 Token 已达上限');
    }
    if (book.tokenSum + incomingTokens >= effective.bookTokenLimit) {
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
