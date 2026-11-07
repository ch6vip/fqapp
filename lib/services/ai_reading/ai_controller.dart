import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chapter_text_formatter.dart';
import '../../models/text_replacement_rule.dart';
import '../text_replacement_engine.dart';
import 'ai_budget.dart';
import 'ai_chapter_snapshot.dart';
import 'ai_coordinator.dart';
import 'ai_display_composition.dart';
import 'ai_feedback.dart';
import 'ai_models.dart';
import 'ai_request_foreground.dart';
import 'ai_settings.dart';
import 'ai_store.dart';

class AiChapterView {
  const AiChapterView({
    required this.bookId,
    required this.chapterId,
    required this.snapshot,
    required this.composition,
    required this.mode,
    required this.status,
    required this.aiEnabled,
    required this.consent,
    this.lastError,
  });

  final String bookId;
  final String chapterId;
  final AiChapterSnapshot snapshot;
  final AiCompositionResult composition;
  final AiDisplayMode mode;
  final String status;
  final bool aiEnabled;
  final bool consent;
  final String? lastError;

  bool get hasCache => composition.formal != null;
  int get editCount => composition.formal?.edits.length ?? 0;
  int get visibleCount =>
      _visibleCount(composition.formal, composition.skippedByProtection) +
      composition.approvedCount;

  static int _visibleCount(AiFormalCacheEntry? formal, int skipped) {
    final total = formal?.edits.length ?? 0;
    return (total - skipped).clamp(0, total);
  }
}

/// Process-wide facade used by the reader, settings pages and backup.
///
/// It owns no BuildContext. Every operation is safe to call before [init]
/// completes; the store/settings then report unavailable and callers degrade to
/// the original chapter.
class AiReadingController extends ChangeNotifier {
  AiReadingController._();
  static final instance = AiReadingController._();

  final _settings = AiSettingsStore.instance;
  final _store = AiStore.instance;
  final _composition = AiDisplayComposition.instance;
  final _coordinator = AiCoordinator.instance;
  final _budget = AiBudgetService.instance;

  bool _initialized = false;
  Future<void>? _initFuture;
  int revision = 0;
  int _prefetchEpoch = 0;
  final _status = <String, AiChapterRunStatus>{};
  final _inflight = <String, Future<AiTaskResult?>>{};
  final _cancels = <String, Completer<void>>{};
  final _forcedRefreshQueued = <String>{};
  final _progress = <String, ValueNotifier<AiStreamProgress?>>{};
  final _statusRecorded = <String>{};
  final _knownDisplays =
      <String, ({String bookId, String hash, int revision})>{};

  /// The last content-derived display revision seen by a reader, or null when
  /// this chapter has no composition yet / it was invalidated. The reader uses
  /// this to avoid composing the whole chapter for unrelated status updates.
  int? knownDisplayRevision(
    String bookId,
    String chapterId,
    String? canonicalHash,
  ) {
    if (canonicalHash == null) return null;
    final entry = _knownDisplays[_chapterKey(bookId, chapterId)];
    if (entry == null || entry.hash != canonicalHash) return null;
    return entry.revision;
  }

  void _recordDisplay(
    String bookId,
    String chapterId,
    String hash,
    int revision,
  ) {
    _knownDisplays[_chapterKey(bookId, chapterId)] = (
      bookId: bookId,
      hash: hash,
      revision: revision,
    );
  }

  void _invalidateDisplays({String? bookId, String? hash}) {
    if (bookId == null && hash == null) {
      _knownDisplays.clear();
      return;
    }
    _knownDisplays.removeWhere((_, entry) {
      if (bookId != null && entry.bookId != bookId) return false;
      if (hash != null && entry.hash != hash) return false;
      return true;
    });
  }

  AiSettingsStore get settings => _settings;
  AiStore get store => _store;
  AiBudgetService get budget => _budget;

  bool get isReady =>
      _initialized && _settings.isAvailable && _store.isAvailable;
  String? get unavailableReason => _settings.status ?? _store.status;

  Future<void> init() {
    if (_initialized) return Future.value();
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    await _settings.init();
    await _store.init();
    try {
      // Shared gate: a probe started before this init must not be mistaken for
      // a leftover reservation when recovery runs.
      await AiBudgetService.instance.ensureRecovered();
      await _store.recoverInterruptedChapterStatuses();
      await _store.prune();
    } catch (_) {
      // Retention cleanup must never block reading.
    }
    _initialized = true;
    _settings.addListener(_onSettingsChanged);
    AiFeedbackService.instance.addListener(_onSettingsChanged);
    notifyListeners();
  }

  void _onSettingsChanged() {
    // Settings and feedback can change the effective mode or protection layer.
    // Invalidate the cheap display cache; the composition itself still gates
    // the actual layout rebuild.
    _invalidateDisplays();
    revision++;
    notifyListeners();
  }

  String _chapterKey(String bookId, String chapterId) =>
      '$bookId\u0000$chapterId';

  AiChapterRunStatus statusFor(String bookId, String chapterId) =>
      _status[_chapterKey(bookId, chapterId)] ?? AiChapterRunStatus.idle();

  ValueNotifier<AiStreamProgress?> progressFor(
    String bookId,
    String chapterId,
  ) => _progress.putIfAbsent(
    _chapterKey(bookId, chapterId),
    () => ValueNotifier<AiStreamProgress?>(null),
  );

  AiCompositionConfig configFor(String bookId) {
    final effective = _settings.resolve(bookId);
    return AiCompositionConfig(
      aiRequestEnabled: effective.enabled,
      displayMode: effective.displayMode,
    );
  }

  Future<AiChapterView> viewFor({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required ChapterContent content,
    required TextReplacementSnapshot customSnapshot,
    bool temporaryOriginal = false,
    int? previewSourceStart,
    int? previewSourceEnd,
    TextReplacementEngine? replacementEngine,
  }) async {
    // Reading never waits for AI storage. The app boot and settings pages
    // start [init]; before it finishes, compose with defaults and re-render
    // when the store notifies.
    final snapshot = AiChapterSnapshotBuilder.fromContent(
      content,
      chapterTitle,
    );
    final effective = _settings.resolve(bookId);
    final config = AiCompositionConfig(
      aiRequestEnabled: effective.enabled,
      displayMode: effective.displayMode,
      temporaryOriginal: temporaryOriginal,
      previewSourceStart: previewSourceStart,
      previewSourceEnd: previewSourceEnd,
    );
    final composition = await _composition.compose(
      bookId: bookId,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      content: content,
      snapshot: snapshot,
      customSnapshot: customSnapshot,
      config: config,
      replacementEngine: replacementEngine,
    );
    final formal = composition.formal;
    if (formal != null) {
      final recorded = '$bookId\u0000$chapterId\u0000${formal.canonicalHash}';
      if (_statusRecorded.add(recorded)) {
        unawaited(
          _store
              .putChapterStatus(
                AiChapterCheckStatus(
                  bookId: bookId,
                  chapterId: chapterId,
                  chapterVersion: '',
                  state: AiChapterCheckState.checked,
                  canonicalHash: formal.canonicalHash,
                  updatedAt: DateTime.now(),
                ),
              )
              .catchError((_) {}),
        );
      }
    }
    _recordDisplay(
      bookId,
      chapterId,
      snapshot.canonicalHash,
      composition.displayRevision,
    );
    final status = statusFor(bookId, chapterId);
    final label = _statusLabel(
      effective: effective,
      composition: composition,
      status: status,
      config: config,
    );
    return AiChapterView(
      bookId: bookId,
      chapterId: chapterId,
      snapshot: snapshot,
      composition: composition,
      mode: config.effectiveMode,
      status: label,
      aiEnabled: effective.enabled,
      consent:
          _settings.device.cloudConsent && !_settings.device.deviceDisabled,
      lastError: status.error ?? composition.error,
    );
  }

  String _statusLabel({
    required AiEffectiveSettings effective,
    required AiCompositionResult composition,
    required AiChapterRunStatus status,
    required AiCompositionConfig config,
  }) {
    if (!effective.enabled) return 'AI 阅读优化已关闭';
    if (_settings.device.deviceDisabled) return '本机已停用 AI 请求';
    if (!_settings.device.cloudConsent) return '需要同意云端正文传输';
    if (status.running) return '校对中';
    if (status.error != null) return '失败，显示原文';
    if (config.effectiveMode == AiDisplayMode.original) {
      final count = composition.formal?.edits.length ?? 0;
      return count == 0 ? '显示原文' : '显示原文，已缓存 $count 处修改';
    }
    if (config.effectiveMode == AiDisplayMode.customOnly) {
      final count = composition.formal?.edits.length ?? 0;
      return count == 0 ? '仅自定义替换' : '显示自定义替换，已缓存 $count 处 AI 修改';
    }
    if (composition.formal != null) {
      if (composition.formal!.edits.isEmpty) return '本章无需修改';
      final visible =
          composition.formal!.edits.length -
          composition.skippedByProtection +
          composition.approvedCount;
      if (visible <= 0) return '修改均被锁定跳过';
      return '已应用 $visible 处修改';
    }
    return '未校对';
  }

  /// Starts a real request. [automatic] means prefetch: over-budget stops
  /// silently instead of asking for confirmation. Manual calls can return
  /// `needsBudgetConfirmation`; the UI then asks and retries with
  /// [confirmedOverBudget].
  Future<AiTaskResult?> requestChapter({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required ChapterContent content,
    String? chapterVersion,
    bool forceRefresh = false,
    bool automatic = false,
    bool confirmedOverBudget = false,
  }) async {
    if (!_initialized) return null;
    await init();
    if (!isReady) return null;
    // Ask once for the notification permission used by the foreground
    // service. Denial only hides the system stop action; it must not block the
    // request itself.
    unawaited(AiRequestForeground.ensureNotificationPermission());
    final AiChapterSnapshot snapshot;
    try {
      snapshot = AiChapterSnapshotBuilder.fromContent(content, chapterTitle);
    } on AiSnapshotException {
      return null;
    }
    // A chapter may have only one in-flight request. Different chapters can
    // still run concurrently, and the formal cache remains hash-keyed.
    final key = _chapterKey(bookId, chapterId);
    final existing = _inflight[key];
    if (existing != null) {
      if (!forceRefresh || !_forcedRefreshQueued.add(key)) return existing;
      try {
        await existing;
      } catch (_) {
        // A failed in-flight task must not swallow the explicit refresh.
      } finally {
        _forcedRefreshQueued.remove(key);
      }
      return requestChapter(
        bookId: bookId,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        content: content,
        chapterVersion: chapterVersion,
        forceRefresh: true,
        automatic: automatic,
        confirmedOverBudget: confirmedOverBudget,
      );
    }
    final future = _runRequest(
      bookId: bookId,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      content: content,
      snapshot: snapshot,
      chapterVersion: chapterVersion,
      forceRefresh: forceRefresh,
      automatic: automatic,
      confirmedOverBudget: confirmedOverBudget,
    );
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    }
  }

  Future<AiTaskResult?> _runRequest({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required ChapterContent content,
    required AiChapterSnapshot snapshot,
    required String? chapterVersion,
    required bool forceRefresh,
    required bool automatic,
    required bool confirmedOverBudget,
  }) async {
    final key = _chapterKey(bookId, chapterId);
    final effective = _settings.resolve(bookId);
    if (!effective.enabled) return null;
    if (!_settings.device.cloudConsent || _settings.device.deviceDisabled) {
      return null;
    }
    _status[key] = AiChapterRunStatus.running();
    await _store.putChapterStatus(
      AiChapterCheckStatus(
        bookId: bookId,
        chapterId: chapterId,
        chapterVersion: chapterVersion ?? '',
        state: AiChapterCheckState.running,
        canonicalHash: snapshot.canonicalHash,
        updatedAt: DateTime.now(),
      ),
    );
    final progress = progressFor(bookId, chapterId);
    progress.value = null;
    notifyListeners();
    var notificationText = '';
    void updateNotification(String text) {
      if (notificationText == text) return;
      notificationText = text;
      unawaited(AiRequestForeground.updateNotification(text));
    }

    updateNotification('正在连接模型…');
    final cancellation = Completer<void>();
    _cancels[key] = cancellation;
    try {
      final result = await _coordinator.runFormal(
        bookId: bookId,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        content: content,
        kind: forceRefresh ? AiRunKind.formalRefresh : AiRunKind.formalFirst,
        forceRefresh: forceRefresh,
        automatic: automatic,
        confirmedOverBudget: confirmedOverBudget,
        cancelTrigger: cancellation.future,
        onState: (state) {
          final current = _status[key];
          if (current == null) return;
          _status[key] = current.copyWith(running: true, state: state);
          final status = switch (state) {
            AiRunState.running => '正在连接模型…',
            AiRunState.validating => '正在校验修改…',
            AiRunState.repairing => '正在重试校对…',
            AiRunState.cancelled => '正在停止…',
            _ => null,
          };
          if (status != null) updateNotification(status);
          notifyListeners();
        },
        onProgress: (value) {
          progress.value = value;
          updateNotification(
            value.contentChars == 0 && value.reasoningChars > 0
                ? '正在思考…'
                : value.contentChars > 0
                ? '正在生成修改…'
                : '正在连接模型…',
          );
        },
        onNotice: (message) {
          progress.value = (progress.value ?? const AiStreamProgress())
              .copyWith(notice: message);
          updateNotification('思考用尽输出，正在重试');
        },
      );
      _status[key] = AiChapterRunStatus(
        running: false,
        success: result.ok,
        error: result.error,
        formal: result.formal,
        needsBudgetConfirmation: result.needsBudgetConfirmation,
        budgetMessage: result.budgetMessage,
        state: result.ok
            ? AiRunState.success
            : result.errorCodes.contains('REQUEST_ABORTED')
            ? AiRunState.cancelled
            : AiRunState.failed,
      );
      await _store.putChapterStatus(
        AiChapterCheckStatus(
          bookId: bookId,
          chapterId: chapterId,
          chapterVersion: chapterVersion ?? '',
          state: result.ok
              ? AiChapterCheckState.checked
              : AiChapterCheckState.failed,
          canonicalHash: result.snapshot.canonicalHash,
          errorCode: result.errorCodes.isEmpty ? null : result.errorCodes.first,
          updatedAt: DateTime.now(),
        ),
      );
      _invalidateDisplays(bookId: bookId, hash: result.snapshot.canonicalHash);
      revision++;
      notifyListeners();
      return result;
    } catch (error) {
      _status[key] = AiChapterRunStatus(
        running: false,
        success: false,
        error: '$error',
        state: AiRunState.failed,
      );
      try {
        await _store.putChapterStatus(
          AiChapterCheckStatus(
            bookId: bookId,
            chapterId: chapterId,
            chapterVersion: chapterVersion ?? '',
            state: AiChapterCheckState.failed,
            canonicalHash: snapshot.canonicalHash,
            errorCode: 'EXCEPTION',
            updatedAt: DateTime.now(),
          ),
        );
      } catch (_) {}
      revision++;
      notifyListeners();
      return null;
    } finally {
      if (identical(_cancels[key], cancellation)) {
        _cancels.remove(key);
      }
    }
  }

  /// Called after an external restore/rebind writes chapters or protections.
  /// Display versions are content-derived, so clearing transient status and
  /// notifying is enough; the reader will recompose only if the final display
  /// actually changed.
  void notifyExternalDataChanged() {
    _status.clear();
    _statusRecorded.clear();
    _invalidateDisplays();
    revision++;
    notifyListeners();
  }

  Future<void> clearFormalCache() async {
    cancelPrefetch();
    await _store.clearFormal();
    _status.clear();
    _statusRecorded.clear();
    _invalidateDisplays();
    revision++;
    notifyListeners();
  }

  /// Removes the formal results for a set of books, leaving every other AI
  /// asset (feedback, protections, prompts, usage) intact.
  Future<void> clearFormalCacheForBooks(Set<String> bookIds) async {
    if (bookIds.isEmpty) return;
    cancelPrefetch();
    await _store.clearFormalForBooks(bookIds);
    _status.removeWhere((key, _) {
      final separator = key.indexOf('\u0000');
      return separator > 0 && bookIds.contains(key.substring(0, separator));
    });
    _statusRecorded.removeWhere((key) {
      final separator = key.indexOf('\u0000');
      return separator > 0 && bookIds.contains(key.substring(0, separator));
    });
    for (final bookId in bookIds) {
      _invalidateDisplays(bookId: bookId);
    }
    revision++;
    notifyListeners();
  }

  /// Removes formal results by canonical hash for one book. Chapters that
  /// share the same 正文 hash share one formal entry, so their status rows are
  /// removed together and the directory falls back to「未校验」.
  Future<void> clearFormalCacheForHashes(
    String bookId,
    Set<String> hashes,
  ) async {
    if (hashes.isEmpty) return;
    cancelPrefetch();
    await _store.clearFormalForHashes(bookId, hashes);
    _status.removeWhere((key, _) => key.startsWith('$bookId\u0000'));
    _statusRecorded.removeWhere((key) => key.startsWith('$bookId\u0000'));
    for (final hash in hashes) {
      _invalidateDisplays(bookId: bookId, hash: hash);
    }
    revision++;
    notifyListeners();
  }

  Future<List<AiChapterCheckStatus>> chapterStatuses(String bookId) async {
    if (!_initialized) return const [];
    return _store.chapterStatuses(bookId);
  }

  /// Stops the request for one chapter. The in-flight HTTP call is aborted;
  /// the provider may still have received it, so the request ledger keeps the
  /// usage as unknown rather than pretending it never happened.
  void cancelChapterRequest(String bookId, String chapterId) {
    unawaited(AiRequestForeground.updateNotification('正在停止…'));
    final cancel = _cancels.remove(_chapterKey(bookId, chapterId));
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  /// Cancels queued prefetch work. An HTTP request that is already in flight
  /// cannot be un-billed, but no further chapter will be requested.
  void cancelPrefetch() {
    _prefetchEpoch++;
  }

  /// Called by the reader when the progress crosses the configured trigger.
  Future<void> maybePrefetch({
    required String bookId,
    required String nextChapterId,
    required String nextChapterTitle,
    required ChapterContent nextContent,
    String? nextChapterVersion,
    required double chapterProgress,
  }) async {
    if (!_initialized) return;
    final epoch = _prefetchEpoch;
    await init();
    if (!isReady) return;
    if (epoch != _prefetchEpoch) return;
    final effective = _settings.resolve(bookId);
    if (!effective.enabled || !effective.prefetchEnabled) return;
    if (effective.displayMode != AiDisplayMode.aiOptimized) return;
    if (!_settings.device.cloudConsent || _settings.device.deviceDisabled) {
      return;
    }
    if (chapterProgress < effective.prefetchTriggerRatio) return;
    final AiChapterSnapshot snapshot;
    try {
      snapshot = AiChapterSnapshotBuilder.fromContent(
        nextContent,
        nextChapterTitle,
      );
    } on AiSnapshotException {
      return;
    }
    if (_inflight.containsKey(_chapterKey(bookId, nextChapterId))) {
      return;
    }
    final cached = await _store.formal(bookId, snapshot.canonicalHash);
    if (epoch != _prefetchEpoch) return;
    if (cached != null) {
      await _store.putChapterStatus(
        AiChapterCheckStatus(
          bookId: bookId,
          chapterId: nextChapterId,
          chapterVersion: nextChapterVersion ?? '',
          state: AiChapterCheckState.checked,
          canonicalHash: snapshot.canonicalHash,
          updatedAt: DateTime.now(),
        ),
      );
      _status[_chapterKey(bookId, nextChapterId)] = AiChapterRunStatus(
        running: false,
        success: true,
        formal: cached,
        state: AiRunState.success,
      );
      revision++;
      notifyListeners();
      return;
    }
    await requestChapter(
      bookId: bookId,
      chapterId: nextChapterId,
      chapterTitle: nextChapterTitle,
      content: nextContent,
      chapterVersion: nextChapterVersion,
      automatic: true,
    );
  }

  Future<void> setDisplayMode(String bookId, AiDisplayMode mode) async {
    final overrides = _settings.bookOverrides(bookId);
    if (overrides.containsKey('displayMode')) {
      await _settings.setBookOverride(bookId, 'displayMode', mode.name);
    } else {
      await _settings.saveGlobal(_settings.global.copyWith(displayMode: mode));
    }
    _invalidateDisplays();
    revision++;
    notifyListeners();
  }

  Future<void> setBookDisplayMode(String bookId, AiDisplayMode? mode) async {
    if (mode == null) {
      await _settings.clearBookOverride(bookId, 'displayMode');
    } else {
      await _settings.setBookOverride(bookId, 'displayMode', mode.name);
    }
    _invalidateDisplays();
    revision++;
    notifyListeners();
  }

  Future<void> setEnabled(String bookId, bool enabled) async {
    if (!enabled) cancelPrefetch();
    final overrides = _settings.bookOverrides(bookId);
    if (overrides.containsKey('enabled')) {
      await _settings.setBookOverride(bookId, 'enabled', enabled);
    } else {
      await _settings.saveGlobal(_settings.global.copyWith(enabled: enabled));
    }
    _invalidateDisplays();
    revision++;
    notifyListeners();
  }

  Future<void> setCloudConsent(bool value) async {
    if (!value) cancelPrefetch();
    await _settings.saveDevice(_settings.device.copyWith(cloudConsent: value));
    _invalidateDisplays();
    revision++;
    notifyListeners();
  }
}

class AiChapterRunStatus {
  const AiChapterRunStatus({
    required this.running,
    required this.success,
    required this.state,
    this.error,
    this.formal,
    this.needsBudgetConfirmation = false,
    this.budgetMessage,
  });

  factory AiChapterRunStatus.idle() => const AiChapterRunStatus(
    running: false,
    success: false,
    state: AiRunState.interrupted,
  );

  factory AiChapterRunStatus.running() => const AiChapterRunStatus(
    running: true,
    success: false,
    state: AiRunState.running,
  );

  final bool running;
  final bool success;
  final AiRunState state;
  final String? error;
  final AiFormalCacheEntry? formal;
  final bool needsBudgetConfirmation;
  final String? budgetMessage;

  AiChapterRunStatus copyWith({
    bool? running,
    bool? success,
    AiRunState? state,
    String? error,
    AiFormalCacheEntry? formal,
    bool? needsBudgetConfirmation,
    String? budgetMessage,
  }) => AiChapterRunStatus(
    running: running ?? this.running,
    success: success ?? this.success,
    state: state ?? this.state,
    error: error ?? this.error,
    formal: formal ?? this.formal,
    needsBudgetConfirmation:
        needsBudgetConfirmation ?? this.needsBudgetConfirmation,
    budgetMessage: budgetMessage ?? this.budgetMessage,
  );
}
