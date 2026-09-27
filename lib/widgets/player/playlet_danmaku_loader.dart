/// 弹幕分段预加载与 seek 补数的调度器。
///
/// 官方依据（本批重新核实，见
/// docs/validation/short-drama-danmaku-prefetch-20260927.md）：
/// - `DanmakuRequestHelper.java:408-456`：单飞 + 等待队列；`ON_SEEK_FINISH`
///   先重置 `hasMore`，命中已取数缓存则直接跳过；重试预算初值 8。
/// - `DanmakuRequestHelper.java:301-329`：seek 请求把 cursor 清空后按
///   目标毫秒取数；成功后 `hasMore`/`cursor` 跟随回包。
/// - `DanmakuRequestHelper.java:246-261`（`C()`）：成功回包把
///   `[本次请求时间, extra.next_query_danmaku_list_time)` 记成待预取区间；
///   进度进入该区间时按区间右端（未覆盖处）补拉下一批，且只发一次。
/// - `list/a.java:145-163`（`p()`）：已取数缓存按**秒粒度**判定
///   `[start, end)` 是否覆盖当前进度。
/// - `list/a.java:399-483`（`q()`）：重叠/相接区间合并成有序列表。
/// - `container/l.java:1321-1328`：每次进度回调做两件事——当前位置未覆盖
///   则补数（带缓存检查）、进入待预取区间则预取下一批。
///
/// 与官方的差异（都是收窄，不放大请求量）：
/// - 官方等待队列保留每一项（±1 秒去重后逐个补发）；这里单飞之外只保留
///   **最新意图**且 seek 优先，因为覆盖检查每秒都会重新推导需求，被替换的
///   意图会在下一轮重新产生。
/// - 官方失败后立即出队重试；这里隔 1 秒再重试，避免本地核心抖动时热循环。
///   换了目标的 seek，或下一次真正发出的请求，会取消尚未触发的旧重试，
///   避免旧位置在新请求成功后覆盖 cursor 和已覆盖区间。同一秒、游标为空的
///   首批或 seek 已在飞时不再重排，也不作废它自己的失败重试。
/// - 回包缺 `next_query_danmaku_list_time` 时（真实回包未取证到缺失情形），
///   已覆盖区间只记 `[start, start+1s)` 防同点重复请求；不足部分靠后续
///   进度补数按 cursor 续拉，宁可多问不可漏弹幕。
library;

import 'dart:async';

import '../../models/playlet_comment.dart';

/// 请求动因，对应官方 `RequestFrom`（ON_VIDEO_PLAY/ON_SEEK_FINISH/
/// ON_PROGRESS_UPDATE/PRE_REQUEST），测试用它断言调度时机。
enum DanmakuRequestReason { initial, seek, progressRefill, prefetch }

/// 一次弹幕取数请求的参数；series 与时长由页面侧的 fetch 实现补充。
class DanmakuFetchRequest {
  const DanmakuFetchRequest({
    required this.vid,
    required this.startOffsetMs,
    required this.cursor,
    required this.reason,
  });

  final String vid;
  final int startOffsetMs;
  final String cursor;
  final DanmakuRequestReason reason;

  @override
  String toString() =>
      'DanmakuFetchRequest($reason vid=$vid at=${startOffsetMs}ms '
      'cursor=$cursor)';
}

/// 一段已取数的媒体时间区间（毫秒，判定时按官方折算成秒粒度）。
class _CoveredSpan {
  _CoveredSpan(this.startSec, this.endSec);

  int startSec;
  int endSec;
}

/// 弹幕取数调度：按当前视频维护「已覆盖区间 + 待预取区间 + 单飞请求」，
/// 向时间轴输出增量页面。纯 Dart，无 Flutter 依赖，方便用可控时序夹具
/// 覆盖竞态与生命周期。
// Note: 单飞 + 最新意图排队、重试预算收窄与证据缺口 — 见
// .agents/notes/implemented/feature/2026-09-27-danmaku-prefetch-seek.md
// Note: 历史进度补数、取消过期重试、时间轴上限 — 见
// .agents/notes/implemented/bug-fix/2026-09-27-danmaku-resume-retry-cap.md
class DanmakuLoader {
  DanmakuLoader({required this.fetch, this.onLoad});

  /// 官方重试预算初值（`DanmakuRequestHelper` 的 `n`，静态配置 `s`=8）。
  static const _maxRetries = 8;

  /// 本地选择：失败重试间隔。官方是出队即重发；这里隔 1 秒。
  static const _retryDelay = Duration(seconds: 1);

  /// 回包缺 `next_query_danmaku_list_time` 时的最小已覆盖跨度，只防
  /// 同一秒重复请求（见库注释的证据缺口说明）。
  static const _fallbackSpanMs = 1000;

  /// 取数实现：页面默认接 `ApiClient.playletDanmaku`，测试注入可控夹具。
  final Future<PlayletCommentPage> Function(DanmakuFetchRequest request) fetch;

  /// 每次成功回包的增量弹幕；宿主把它并进时间轴（时间轴按 id 去重）。
  final void Function(List<PlayletComment> page)? onLoad;

  String _vid = '';
  int _generation = 0;
  final List<_CoveredSpan> _covered = [];
  ({int startMs, int endMs})? _pendingPrefetch;
  String _cursor = '';
  bool _hasMore = true;
  int _retriesLeft = _maxRetries;
  bool _fetching = false;
  bool _enabled = true;
  bool _disposed = false;
  DanmakuFetchRequest? _queued;
  DanmakuFetchRequest? _inflight;
  Timer? _retryTimer;
  int _epoch = 0;

  /// 测试观察用：当前是否有请求在飞。
  bool get fetching => _fetching;

  /// 当前调度所属视频。空字符串表示还没 [reset]，页面据此判断
  /// 历史进度要不要先记下来等首批请求。
  String get videoId => _vid;

  /// 切集/首集：整池作废（官方 `w()`），随后按起始时间发首批请求。
  void reset({required String vid, int startMs = 0}) {
    _vid = vid;
    _generation++;
    _cancelRetry();
    _covered.clear();
    _pendingPrefetch = null;
    _cursor = '';
    _hasMore = true;
    _retriesLeft = _maxRetries;
    _queued = null;
    _inflight = null;
    _fetching = false;
    if (_disposed || !_enabled || vid.isEmpty) return;
    _dispatch(
      DanmakuFetchRequest(
        vid: vid,
        startOffsetMs: startMs < 0 ? 0 : startMs,
        cursor: '',
        reason: DanmakuRequestReason.initial,
      ),
    );
  }

  /// 拖动/横滑/快进/回拖的最终目标（官方 `ON_SEEK_FINISH`）。
  /// 目标已被已取数区间覆盖时按官方跳过；暂停中同样允许补数。
  ///
  /// 本地选择：seek 同时重置重试预算（官方对 seek 失败不扣预算但也不
  /// 重置；这里统一为每次 seek 给满预算，保证拖动总能拿到附近弹幕）。
  void onSeek(int targetMs) {
    if (_disposed || !_enabled || _vid.isEmpty || targetMs < 0) return;
    if (_coveredAt(targetMs)) {
      // 目标已有数据。旧失败重试不能再发出去改游标。
      _cancelRetry();
      return;
    }
    final inflight = _inflight;
    if (_fetching &&
        inflight != null &&
        inflight.cursor.isEmpty &&
        inflight.startOffsetMs ~/ 1000 == targetMs ~/ 1000 &&
        (inflight.reason == DanmakuRequestReason.initial ||
            inflight.reason == DanmakuRequestReason.seek)) {
      // 首批或上一次 seek 已经在要这个时间点。不重排，也不作废它的
      // 失败重试：历史恢复会在 reset 之后再回调一次同一秒的 seek。
      return;
    }
    // 失败后的 1 秒重试窗口里如果已经发生 seek，旧位置不能再发出去。
    _cancelRetry();
    _hasMore = true;
    _retriesLeft = _maxRetries;
    _submit(
      DanmakuFetchRequest(
        vid: _vid,
        startOffsetMs: targetMs,
        cursor: '',
        reason: DanmakuRequestReason.seek,
      ),
    );
  }

  /// 播放进度心跳（页面按 1 秒节流喂入，官方是每个进度回调）：
  /// 进入待预取区间则补拉下一批；落在未覆盖处则按当前位置补数。
  void onProgress(int positionMs) {
    if (_disposed || !_enabled || _vid.isEmpty || positionMs < 0) return;
    if (!_hasMore) return;
    final pending = _pendingPrefetch;
    if (pending != null &&
        positionMs >= pending.startMs &&
        positionMs < pending.endMs) {
      // 只发一次：进入区间即清掉待预取标记（官方 `C()` 的语义）。
      _pendingPrefetch = null;
      _submit(
        DanmakuFetchRequest(
          vid: _vid,
          startOffsetMs: pending.endMs,
          cursor: _cursor,
          reason: DanmakuRequestReason.prefetch,
        ),
      );
      return;
    }
    if (!_coveredAt(positionMs)) {
      _submit(
        DanmakuFetchRequest(
          vid: _vid,
          startOffsetMs: positionMs,
          cursor: _cursor,
          reason: DanmakuRequestReason.progressRefill,
        ),
      );
    }
  }

  /// 开关弹幕。关闭后不再发任何请求（含排队与重试）；重新开启由页面
  /// 按当前进度调 [onProgress] 恢复取数。
  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) {
      _cancelRetry();
      _queued = null;
    }
  }

  void dispose() {
    _disposed = true;
    _enabled = false;
    _cancelRetry();
    _queued = null;
    _covered.clear();
    _pendingPrefetch = null;
  }

  /// 时间轴丢掉超出上限的条目后，收窄已覆盖区间，避免「缓存说有、
  /// 时间轴已经没有」。只丢掉尾部时清掉 cursor：那条游标属于被丢弃的
  /// 最新一页，继续用它会跳过中间的弹幕。
  void noteRetainedRange({
    required int minOffsetMs,
    required int maxOffsetMs,
    required bool droppedBehind,
    required bool droppedAhead,
    bool emptied = false,
  }) {
    if (_disposed || (!emptied && !droppedBehind && !droppedAhead)) return;
    if (emptied) {
      _covered.clear();
      _pendingPrefetch = null;
      _cursor = '';
      _hasMore = true;
      _dropQueuedPrefetch();
      return;
    }
    final startSec = droppedBehind ? minOffsetMs ~/ 1000 : null;
    final endSec = droppedAhead ? maxOffsetMs ~/ 1000 + 1 : null;
    final clipped = <_CoveredSpan>[];
    for (final span in _covered) {
      final lower = startSec != null && span.startSec < startSec
          ? startSec
          : span.startSec;
      final upper = endSec != null && span.endSec > endSec
          ? endSec
          : span.endSec;
      if (upper > lower) clipped.add(_CoveredSpan(lower, upper));
    }
    _covered
      ..clear()
      ..addAll(clipped);
    if (droppedAhead) {
      _cursor = '';
      _pendingPrefetch = null;
      _hasMore = true;
      _dropQueuedPrefetch();
      return;
    }
    final pending = _pendingPrefetch;
    if (pending != null &&
        startSec != null &&
        pending.endMs ~/ 1000 <= startSec) {
      _pendingPrefetch = null;
    }
  }

  void _dropQueuedPrefetch() {
    final queued = _queued;
    if (queued != null && queued.reason != DanmakuRequestReason.seek) {
      _queued = null;
    }
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _epoch++;
  }

  /// 单飞 + 最新意图：在飞时只保留一个排队项。最新的 seek 压过一切
  /// （快速连续 seek 只补最终目标）；非 seek 意图互相替换，但不顶掉
  /// 已排队的 seek（进度类的需求下一秒心跳会重新推导）。
  void _submit(DanmakuFetchRequest request) {
    if (_disposed) return;
    if (_fetching) {
      final current = _queued;
      final currentIsSeek = current?.reason == DanmakuRequestReason.seek;
      if (current == null ||
          !currentIsSeek ||
          request.reason == DanmakuRequestReason.seek) {
        _queued = request;
      }
      return;
    }
    _dispatch(request);
  }

  Future<void> _dispatch(DanmakuFetchRequest request) async {
    if (_disposed || !_enabled) return;
    _cancelRetry();
    final generation = _generation;
    final epoch = _epoch;
    _fetching = true;
    _inflight = request;
    PlayletCommentPage page;
    try {
      page = await fetch(request);
    } catch (_) {
      // 旧代际的失败不动新代际的单飞标志：切集后旧请求迟到时，
      // 新视频的请求可能还在飞。
      if (_disposed || generation != _generation) return;
      _fetching = false;
      if (identical(_inflight, request)) _inflight = null;
      if (_retriesLeft > 0) {
        _retriesLeft--;
        _retryTimer = Timer(_retryDelay, () {
          _retryTimer = null;
          if (_disposed || !_enabled || generation != _generation) return;
          if (epoch != _epoch) return;
          // 预算用尽就不再重试（官方在 tryRequest 入口按 n<=0 拦截）。
          if (_retriesLeft <= 0) return;
          // 失败按原意图重试；排队里有更新意图（如更新的 seek）则优先它。
          // 走 _submit 保持单飞：定时器等待期间可能有新请求已经起飞。
          final retry = _queued ?? request;
          _queued = null;
          _submit(retry);
        });
      }
      return;
    }
    if (_disposed || generation != _generation) return;
    _fetching = false;
    if (identical(_inflight, request)) _inflight = null;
    _retriesLeft = _maxRetries;
    _hasMore = page.hasMore;
    _cursor = page.cursor;
    final endMs = page.nextQueryMs > request.startOffsetMs
        ? page.nextQueryMs
        : request.startOffsetMs + _fallbackSpanMs;
    _addCovered(request.startOffsetMs, endMs);
    if (_hasMore && page.nextQueryMs > request.startOffsetMs) {
      _pendingPrefetch = (startMs: request.startOffsetMs, endMs: endMs);
    } else {
      _pendingPrefetch = null;
    }
    onLoad?.call(page.comments);
    final next = _queued;
    _queued = null;
    if (next != null) _dispatch(next);
  }

  /// 官方秒粒度判定（`list/a.p()`）：`start <= t/1000 < end`。
  bool _coveredAt(int positionMs) {
    final sec = positionMs ~/ 1000;
    for (final span in _covered) {
      if (span.startSec <= sec && sec < span.endSec) return true;
    }
    return false;
  }

  /// 合并重叠/相接区间并保持有序（官方 `list/a.q()`）。
  void _addCovered(int startMs, int endMs) {
    final startSec = startMs ~/ 1000;
    final endSec = endMs ~/ 1000;
    if (endSec <= startSec) return;
    final merged = <_CoveredSpan>[];
    var inserted = false;
    for (final span in _covered) {
      if (!inserted && startSec <= span.endSec && endSec >= span.startSec) {
        // 与 [start, end) 重叠或相接的区间并入新区间。
        span.startSec = span.startSec < startSec ? span.startSec : startSec;
        span.endSec = span.endSec > endSec ? span.endSec : endSec;
        merged.add(span);
        inserted = true;
      } else if (inserted && span.startSec <= merged.last.endSec) {
        // 新区间吞掉了相邻旧区间，继续向后并入。
        if (span.endSec > merged.last.endSec) merged.last.endSec = span.endSec;
      } else {
        merged.add(span);
      }
    }
    if (!inserted) merged.add(_CoveredSpan(startSec, endSec));
    merged.sort((a, b) => a.startSec.compareTo(b.startSec));
    _covered
      ..clear()
      ..addAll(merged);
  }
}
