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
    required this.requestId,
    this.runId,
  });

  final String day;

  /// `null` means a global-only reservation from a partial recovery.
  final String? bookId;
  final String displayCurrency;
  final String requestId;

  /// The real Run created before admission. Recovery updates this run instead
  /// of creating a second crash-recovery run when it is available.
  final String? runId;

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
      : daily.totalRequestCount / settings.dailyRequestLimit;
  double get bookRequestRatio => settings.bookRequestLimit <= 0
      ? 0
      : book.totalRequestCount / settings.bookRequestLimit;
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
  Future<void>? _recoveryFuture;

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
    await ensureRecovered();
    if (!_store.isAvailable) {
      return const AiBudgetDecision(
        allowed: false,
        reason: 'AI 数据存储不可用，已停止请求',
        code: 'STORE_UNAVAILABLE',
        usageRatio: 1,
      );
    }
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
    bool requireEnabled = true,
    bool requireConsent = true,
    String? requestId,
    String? runId,
  }) async {
    final reservedRequestId =
        requestId ??
        'req_reserved_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    // Wait for recovery before entering the write queue: recovery itself calls
    // settle(), which uses the same queue.
    await ensureRecovered();
    return _enqueue(() async {
      // Re-read every gate inside the serialized queue. Consent can be revoked
      // while this task waits behind another budget write.
      if (!_store.isAvailable) {
        return const AiBudgetDecision(
          allowed: false,
          reason: 'AI 数据存储不可用，已停止请求',
          code: 'STORE_UNAVAILABLE',
          usageRatio: 1,
        );
      }
      final effective = _settings.resolve(bookId);
      if (requireEnabled && !effective.enabled) {
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
      if (requireConsent && !_settings.device.cloudConsent) {
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
        requestId: reservedRequestId,
        runId: runId,
      );
      final nextDaily = daily.copyWith(
        reservedRequestCount: daily.reservedRequestCount + 1,
        reservedTaskCount: daily.reservedTaskCount + (countTask ? 1 : 0),
        reservedRequestIds: [...daily.reservedRequestIds, reservedRequestId],
        reservedTaskIds: [
          ...daily.reservedTaskIds,
          if (countTask) reservedRequestId,
        ],
        reservedRunIds: runId == null
            ? daily.reservedRunIds
            : {...daily.reservedRunIds, reservedRequestId: runId},
        updatedAt: DateTime.now(),
      );
      final nextBook = book.copyWith(
        reservedRequestCount: book.reservedRequestCount + 1,
        reservedTaskCount: book.reservedTaskCount + (countTask ? 1 : 0),
        reservedRequestIds: [...book.reservedRequestIds, reservedRequestId],
        reservedTaskIds: [
          ...book.reservedTaskIds,
          if (countTask) reservedRequestId,
        ],
        reservedRunIds: runId == null
            ? book.reservedRunIds
            : {...book.reservedRunIds, reservedRequestId: runId},
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
      final targets = <String?, AiBudgetProjection>{};
      try {
        for (final bookId in <String?>[
          null,
          if (reservation.bookId != null) reservation.bookId,
        ]) {
          final current =
              await _store.projection(reservation.day, bookId) ??
              _emptyProjection(
                reservation.day,
                bookId,
                reservation.displayCurrency,
              );
          targets[bookId] = current;
          await _store.putProjection(
            current.copyWith(
              reservedRequestCount: current.reservedRequestCount > 0
                  ? current.reservedRequestCount - 1
                  : 0,
              reservedTaskCount:
                  reservation.countTask && current.reservedTaskCount > 0
                  ? current.reservedTaskCount - 1
                  : current.reservedTaskCount,
              reservedRequestIds: current.reservedRequestIds
                  .where((id) => id != reservation.requestId)
                  .toList(growable: false),
              reservedTaskIds: current.reservedTaskIds
                  .where((id) => id != reservation.requestId)
                  .toList(growable: false),
              reservedRunIds: {
                for (final entry in current.reservedRunIds.entries)
                  if (entry.key != reservation.requestId)
                    entry.key: entry.value,
              },
              updatedAt: DateTime.now(),
            ),
          );
        }
      } catch (_) {
        for (final entry in targets.entries) {
          try {
            await _store.putProjection(entry.value);
          } catch (_) {}
        }
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
        for (final bookId in <String?>[
          null,
          if (reservation.bookId != null) reservation.bookId,
        ]) {
          final current =
              await _store.projection(reservation.day, bookId) ??
              _emptyProjection(
                reservation.day,
                bookId,
                reservation.displayCurrency,
              );
          targets[bookId] = current;
          if (!current.reservedRequestIds.contains(reservation.requestId)) {
            continue;
          }
          final costs = <String, int>{...current.costsByCurrency};
          final cost = request.costMicros ?? 0;
          if (cost != 0) {
            costs[currency] = (costs[currency] ?? 0) + cost;
          }
          await _store.putProjection(
            current.copyWith(
              requestCount: current.requestCount + 1,
              taskCount: current.taskCount + (reservation.countTask ? 1 : 0),
              reservedRequestCount: current.reservedRequestCount > 0
                  ? current.reservedRequestCount - 1
                  : 0,
              reservedTaskCount:
                  reservation.countTask && current.reservedTaskCount > 0
                  ? current.reservedTaskCount - 1
                  : current.reservedTaskCount,
              reservedRequestIds: current.reservedRequestIds
                  .where((id) => id != reservation.requestId)
                  .toList(growable: false),
              reservedTaskIds: current.reservedTaskIds
                  .where((id) => id != reservation.requestId)
                  .toList(growable: false),
              reservedRunIds: {
                for (final entry in current.reservedRunIds.entries)
                  if (entry.key != reservation.requestId)
                    entry.key: entry.value,
              },
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

  /// One-time startup reconciliation shared by every request entry point. A
  /// probe can start before the reading controller's init; without this gate it
  /// could be mistaken for a leftover reservation by that later init.
  Future<void> ensureRecovered() {
    final pending = _recoveryFuture;
    if (pending != null) return pending;
    final future = _recoverOnce().catchError((Object error, StackTrace stack) {
      // A transient storage failure must not poison every later request.
      _recoveryFuture = null;
      return Future<void>.error(error, stack);
    });
    _recoveryFuture = future;
    return future;
  }

  Future<void> _recoverOnce() async {
    if (!_store.isAvailable) return;
    await _store.recoverInterruptedRuns();
    await recoverOrphanedReservations();
  }

  /// Reconciles reservations left behind by a process kill. The HTTP request
  /// may or may not have been sent. If its request ledger row already exists,
  /// settle it with the real usage; otherwise write one deterministic synthetic
  /// row with unknown usage. The synthetic row is keyed by the reservation's
  /// request ID, so a second recovery never duplicates it.
  Future<void> recoverOrphanedReservations() async {
    if (!_store.isAvailable) return;
    final projections = await _store.projections();
    final books = projections
        .where((projection) => projection.bookId != null)
        .toList(growable: false);
    final seen = <String>{};

    for (final projection in books) {
      for (final requestId in projection.reservedRequestIds) {
        if (!seen.add(requestId)) continue;
        await _recoverReservation(
          day: projection.bucketDay,
          bookId: projection.bookId,
          requestId: requestId,
          displayCurrency: projection.currency,
          countTask: projection.reservedTaskIds.contains(requestId),
          runIdHint: projection.reservedRunIds[requestId],
        );
      }
    }

    // A crash can happen between the global write and the book write. Process
    // any global-only IDs, but never the same ID twice.
    for (final projection in projections.where((p) => p.bookId == null)) {
      for (final requestId in projection.reservedRequestIds) {
        if (!seen.add(requestId)) continue;
        await _recoverReservation(
          day: projection.bucketDay,
          bookId: null,
          requestId: requestId,
          displayCurrency: projection.currency,
          countTask: projection.reservedTaskIds.contains(requestId),
          runIdHint: projection.reservedRunIds[requestId],
        );
      }
    }
  }

  Future<void> _recoverReservation({
    required String day,
    required String? bookId,
    required String requestId,
    required String displayCurrency,
    required bool countTask,
    String? runIdHint,
  }) async {
    final now = DateTime.now();
    var request = await _store.request(requestId);
    if (request == null) {
      request = AiRequestRecord(
        requestId: requestId,
        runId: runIdHint ?? 'run_crash_$requestId',
        attemptNo: 1,
        providerId: 'recovered',
        endpoint: '',
        model: '',
        mode: AiOutputMode.jsonObject,
        usage: const AiUsage(),
        startedAt: now,
        latencyMs: 0,
        errorCode: 'CRASH_RECOVERED',
        reason: 'crash_recovered',
      );
      try {
        await _store.putRequest(request);
      } catch (_) {
        // The projection recovery below must still happen.
      }
    }

    final run = await _store.run(request.runId);
    if (run == null) {
      try {
        await _store.putRun(
          AiRunRecord(
            runId: request.runId,
            kind: AiRunKind.recovered,
            bookId: bookId ?? '',
            chapterId: '',
            canonicalHash: '',
            configSnapshotHash: '',
            state: AiRunState.interrupted,
            attemptCount: 1,
            formalEligible: false,
            startedAt: request.startedAt,
            finishedAt: now,
            errorCodes: const ['CRASH_RECOVERED'],
            detail: '应用异常退出，用量按账本或未知值保守计入',
          ),
        );
      } catch (_) {
        // Counter recovery is still useful without the run row.
      }
    } else if (run.state == AiRunState.running ||
        run.state == AiRunState.validating ||
        run.state == AiRunState.repairing) {
      try {
        await _store.putRun(
          run.copyWith(
            state: AiRunState.interrupted,
            finishedAt: now,
            errorCodes: const ['CRASH_RECOVERED'],
            detail: '应用异常退出，已恢复未结算请求',
          ),
        );
      } catch (_) {}
    }

    await settle(
      reservation: AiBudgetReservation(
        day: day,
        bookId: bookId,
        displayCurrency: displayCurrency,
        countTask: countTask,
        requestId: requestId,
      ),
      request: request,
    );
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
          ? incoming.copyWith(
              reservedRequestCount: 0,
              reservedTaskCount: 0,
              reservedRequestIds: const [],
              reservedTaskIds: const [],
              reservedRunIds: const {},
              costsByCurrency: Map.unmodifiable(costs),
            )
          : incoming.copyWith(
              requestCount: incoming.requestCount > current.requestCount
                  ? incoming.requestCount
                  : current.requestCount,
              taskCount: incoming.taskCount > current.taskCount
                  ? incoming.taskCount
                  : current.taskCount,
              // Never import another device's in-flight slots. Only the
              // current process knows which reservations it can release.
              reservedRequestCount: current.reservedRequestCount,
              reservedTaskCount: current.reservedTaskCount,
              reservedRequestIds: current.reservedRequestIds,
              reservedTaskIds: current.reservedTaskIds,
              reservedRunIds: current.reservedRunIds,
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
    if (daily.totalRequestCount + 1 > effective.dailyRequestLimit) {
      checks.add('今日请求次数已达上限');
    }
    if (book.totalRequestCount + 1 > effective.bookRequestLimit) {
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
        (daily.totalRequestCount + 1) / effective.dailyRequestLimit,
        (book.totalRequestCount + 1) / effective.bookRequestLimit,
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
