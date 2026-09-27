/// 短剧弹幕层：取数、时间轴渲染与开关。
///
/// 官方协议（DanmakuRequestHelper.java:303-329、hy1/l.java:86-113）：
/// - 取数复用评论列表接口，:group_id = **vid**，group_type=30、
///   comment_source=601、server_channel=1000、comment_type=20、
///   count=90；business_param.start_offset_time 与
///   playlet_item_duration 都是**毫秒**
/// - 发送复用 comment/add，commit_source=1500、data_type=20、
///   business_param.offset 毫秒
/// - 时间轴行为（container/l.java）：拖动进度清游标重拉（:1213-1227）、
///   播放中预请求下一段（:1321-1328）、切集清时间线整池重灌（:1496-1528）、
///   暂停只停动画不发请求（:1206-1208）、倍速只改渲染时长
///   (横屏?12000:10000)/speed（:1366-1380）
/// - 开关落盘 video_danmaku_switch_sp 的 key_enable_danmaku_by_user
///   （i95/i.java:81-87），Toast「弹幕已开启」/「弹幕已关闭，长按视频可开启」
///
/// 行数、行高、透明度等视觉参数是本地取值；飞行基准竖横屏均有取证
/// （container/l.java），字号默认取官方 DEFAULT 档 16sp。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/playlet_comment.dart';
import 'playlet_danmaku_settings.dart';

/// 同时出现在屏幕上的弹幕行距（本地取值；官方行距由
/// `vx1/b.java` 按字号度量计算，此处用近似恒量）。
const _trackPitch = 28.0;

/// 一条弹幕在屏幕上飞过的时长基准（官方竖屏 10000ms，横屏 12000ms；
/// `container/l.java:782-784,1371-1373`），实际还要除以弹幕速度与播放倍速。
const _flightBaseMs = 10000.0;
const _flightBaseMsLandscape = 12000.0;

/// 官方弹幕单条上限（`VideoDanmakuSettingConfig` 的 `danmakuTextMaxLength`，
/// 上限值本身随服务端下发，本地取官方默认文案里的常见值 50）。
const danmakuMaxLength = 50;

/// 飞行时长（供渲染层与用例共用）。官方公式
/// `(横屏 ? 12000 : 10000) / (DanmakuSpeed × 播放器倍速)`，
/// 横竖屏切换时实时重算（`container/l.java:782-784,1371-1373` 与
/// 横竖屏回调 `o()` `:1940-1972`）。
double danmakuFlightMs(double rate, {bool landscape = false}) =>
    (landscape ? _flightBaseMsLandscape : _flightBaseMs) / _validRate(rate);

double _validRate(double rate) =>
    !rate.isFinite || rate <= 0 ? 1 : math.max(rate, 0.1);

/// 官方弹幕发送长度提示（VideoDanmakuSettingConfig）：
/// 「弹幕最多输入%d个字」/「弹幕最少输入%d个字」。
String danmakuLengthError(int length, {required int min, required int max}) {
  if (length > max) return '弹幕最多输入$max个字';
  if (length < min) return '弹幕最少输入$min个字';
  return '';
}

/// 官方开关落盘（video_danmaku_switch_sp / key_enable_danmaku_by_user）的
/// 本地等价：键名一致，存在 SharedPreferences 里。
class DanmakuPreference {
  const DanmakuPreference._();

  static const spName = 'video_danmaku_switch_sp';
  static const key = 'key_enable_danmaku_by_user';

  /// 官方三级兜底是 SP -> VideoDanmakuLibraConfig -> 服务端 default_switch；
  /// 后两级在本仓库不可得，本地默认**开启**。
  static const defaultEnabled = true;

  static Future<bool> load() async {
    final store = await SharedPreferences.getInstance();
    return store.getBool('$spName/$key') ?? defaultEnabled;
  }

  static Future<void> save(bool enabled) async {
    final store = await SharedPreferences.getInstance();
    await store.setBool('$spName/$key', enabled);
  }
}

/// 弹幕轴的纯逻辑：把「进度 -> 该显示的弹幕」抽出来，便于离线用例覆盖
/// 官方的四条时间轴规则。
///
/// 官方 `DanmakuDataManager` 不裁弹幕池。工单要求缓存有上限：单次请求
/// `count = 90`（`DanmakuRequestHelper.java:363`），这里保留 4 页。播放头
/// 之前只留一个飞行窗口（[_flightBaseMs]），更早的条目回拖时由 seek 重取。
// Note: 历史进度补数、取消过期重试、时间轴上限 — 见
// .agents/notes/implemented/bug-fix/2026-09-27-danmaku-resume-retry-cap.md
class DanmakuTimeline {
  static const maxEntries = 360;

  /// 播放头之后的保留窗要盖住最长的飞行（横屏 12000ms），否则横屏下
  /// 还在屏幕上的弹幕会被本地裁剪提前丢掉；官方不裁池，这是本地上限。
  static const retainBehindMs = 12000;

  final List<PlayletComment> entries = [];
  bool _loaded = false;

  bool get isEmpty => entries.isEmpty;

  /// 切集：官方清时间线整池重灌（container/l.java:1496-1528）。
  void reset() {
    entries.clear();
    _loaded = false;
  }

  /// 装填一页；同一集重复装填按 id 去重（官方按 vid 整池替换）。
  ///
  /// [focusMs] 是当前播放位置。传入后才启用上限：不传则保持旧调用方的
  /// 全量行为，页面侧每次成功回包都会传。
  DanmakuLoadResult load(
    List<PlayletComment> page, {
    bool replace = false,
    int? focusMs,
  }) {
    if (replace) entries.clear();
    final seen = entries.map((e) => e.id).toSet();
    for (final entry in page) {
      if (seen.add(entry.id)) entries.add(entry);
    }
    entries.sort((a, b) {
      final offset = a.offsetMs.compareTo(b.offsetMs);
      return offset == 0 ? a.id.compareTo(b.id) : offset;
    });
    _loaded = true;
    if (focusMs == null) {
      return DanmakuLoadResult.kept(entries);
    }
    return _trim(focusMs);
  }

  DanmakuLoadResult _trim(int focusMs) {
    final before = entries.length;
    final behindCut = focusMs - retainBehindMs;
    entries.removeWhere((entry) => entry.offsetMs < behindCut);
    var droppedBehind = entries.length != before;
    var droppedAhead = false;
    if (entries.length > maxEntries) {
      var nearest = 0;
      var best = (entries.first.offsetMs - focusMs).abs();
      for (var i = 1; i < entries.length; i++) {
        final distance = (entries[i].offsetMs - focusMs).abs();
        if (distance < best) {
          best = distance;
          nearest = i;
        }
      }
      var lower = nearest;
      var upper = nearest;
      while (upper - lower + 1 < maxEntries &&
          (lower > 0 || upper < entries.length - 1)) {
        final left = lower > 0
            ? (entries[lower - 1].offsetMs - focusMs).abs()
            : 1 << 62;
        final right = upper + 1 < entries.length
            ? (entries[upper + 1].offsetMs - focusMs).abs()
            : 1 << 62;
        if (left <= right && lower > 0) {
          lower--;
        } else if (upper + 1 < entries.length) {
          upper++;
        } else {
          break;
        }
      }
      if (lower > 0) droppedBehind = true;
      if (upper < entries.length - 1) droppedAhead = true;
      if (lower > 0 || upper < entries.length - 1) {
        entries.removeRange(upper + 1, entries.length);
        entries.removeRange(0, lower);
      }
    }
    if (entries.isEmpty) {
      return const DanmakuLoadResult(
        droppedBehind: true,
        droppedAhead: false,
        minOffsetMs: 0,
        maxOffsetMs: 0,
        emptied: true,
      );
    }
    return DanmakuLoadResult(
      droppedBehind: droppedBehind,
      droppedAhead: droppedAhead,
      minOffsetMs: entries.first.offsetMs,
      maxOffsetMs: entries.last.offsetMs,
    );
  }

  /// 媒体时间已经包含倍速，窗口不能再除一次倍速，否则会变成倍速的平方。
  List<PlayletComment> visibleAt(int nowMs) {
    if (entries.isEmpty || nowMs < 0) return const [];
    // offset > now-飞行窗口 且 offset <= now。列表按 offset 有序。
    // 飞行窗口用渲染常量，不跟缓存保留窗口绑在一起。
    final minExclusive = nowMs - _flightBaseMs.toInt();
    final start = _firstAbove(minExclusive);
    final end = _firstAbove(nowMs);
    if (start >= end) return const [];
    return [for (var i = start; i < end; i++) entries[i]];
  }

  /// 第一个 `offsetMs > bound` 的下标；全部都不大于 bound 时返回长度。
  int _firstAbove(int bound) {
    var lower = 0;
    var upper = entries.length;
    while (lower < upper) {
      final mid = (lower + upper) >> 1;
      if (entries[mid].offsetMs <= bound) {
        lower = mid + 1;
      } else {
        upper = mid;
      }
    }
    return lower;
  }

  /// 拖动进度后需要重新装填（官方 seekTo() 清游标）。
  bool get needsReload => !_loaded;
}

/// [DanmakuTimeline.load] 裁掉条目后的结果。页面把它交给调度器收窄覆盖区间。
class DanmakuLoadResult {
  const DanmakuLoadResult({
    required this.droppedBehind,
    required this.droppedAhead,
    required this.minOffsetMs,
    required this.maxOffsetMs,
    this.emptied = false,
  });

  factory DanmakuLoadResult.kept(List<PlayletComment> entries) {
    if (entries.isEmpty) {
      return const DanmakuLoadResult(
        droppedBehind: false,
        droppedAhead: false,
        minOffsetMs: 0,
        maxOffsetMs: 0,
      );
    }
    return DanmakuLoadResult(
      droppedBehind: false,
      droppedAhead: false,
      minOffsetMs: entries.first.offsetMs,
      maxOffsetMs: entries.last.offsetMs,
    );
  }

  final bool droppedBehind;
  final bool droppedAhead;
  final int minOffsetMs;
  final int maxOffsetMs;
  final bool emptied;

  bool get dropped => emptied || droppedBehind || droppedAhead;
}

/// 从上游响应取出弹幕时间轴。
///
/// 模型已读取官方回包的 `expand.offset_time`（毫秒），这里保留原时间轴。
List<PlayletComment> danmakuFromPage(PlayletCommentPage page) =>
    List<PlayletComment>.unmodifiable(page.comments);

/// 弹幕渲染层：按当前进度把时间轴上的弹幕画到屏幕上。
// Note: 200ms 进度事件与逐帧绘制分离，见
// .agents/notes/implemented/bug-fix/2026-09-26-danmaku-frame-clock.md
class PlayletDanmakuLayer extends StatefulWidget {
  const PlayletDanmakuLayer({
    super.key,
    required this.entries,
    required this.position,
    this.rate = 1,
    this.playing = true,
    this.enabled = true,
    this.landscape = false,
    this.settings = const DanmakuSettings(),
  });

  /// 当前时间轴上的弹幕（毫秒坐标）。
  final List<PlayletComment> entries;

  /// 原生低频进度用于校准；两次回报之间由屏幕帧时钟推进。
  final ValueListenable<Duration> position;
  final double rate;

  /// 实际播放状态；暂停、缓冲、拖动和后台时停止帧时钟。
  final bool playing;

  /// 官方开关；关闭时整层不渲染。
  final bool enabled;

  /// 官方横屏飞行 12000ms、竖屏 10000ms（`container/l.java`）。
  final bool landscape;

  /// 弹幕设置（官方 `danmaku_config`）：字号/透明度/速度/行数与横屏密度。
  final DanmakuSettings settings;

  @override
  State<PlayletDanmakuLayer> createState() => _PlayletDanmakuLayerState();
}

class _PlayletDanmakuLayerState extends State<PlayletDanmakuLayer>
    with SingleTickerProviderStateMixin {
  // 原生每 200ms 回报一次。允许短暂抖动，但失联后不能让弹幕一直自己走。
  static const _maxExtrapolationMs = 500.0;

  late final Ticker _ticker;
  late final ValueNotifier<double> _mediaMs;
  late double _lastNativeMs;
  Duration _lastTick = Duration.zero;
  double _sinceSampleMs = 0;
  bool _tickerMode = true;

  /// 当前生效的轨道数（竖屏=设置行数，横屏按密度折算）。
  int _tracks = 4;
  List<PlayletComment> _entries = const [];
  List<_DanmakuFlight> _flights = const [];
  List<_DanmakuFlight> _visible = const [];
  double _visibleAtMs = 0;
  double _nextChangeMs = double.infinity;

  @override
  void initState() {
    super.initState();
    _lastNativeMs = widget.position.value.inMicroseconds / 1000;
    _mediaMs = ValueNotifier(_lastNativeMs);
    _ticker = createTicker(_tick);
    _tracks = widget.settings.lineCount;
    _scheduleEntries();
    widget.position.addListener(_onPosition);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode = TickerMode.valuesOf(context).enabled;
    final previous = _tracks;
    _syncTracks();
    if (previous != _tracks) _scheduleEntries();
    _syncTicker();
  }

  @override
  void didUpdateWidget(PlayletDanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.position, widget.position)) {
      oldWidget.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
      _lastNativeMs = widget.position.value.inMicroseconds / 1000;
      _sinceSampleMs = 0;
      _mediaMs.value = _lastNativeMs;
      _updateVisible(force: true, rebuild: false);
    }
    // 宿主原地更新 DanmakuTimeline.entries，因此需要与快照比较。
    if (!listEquals(_entries, widget.entries)) {
      _scheduleEntries();
    }
    // 横竖屏切换或设置变化都会改变飞行时长与轨道数，整批重排。
    if (oldWidget.landscape != widget.landscape ||
        oldWidget.settings != widget.settings) {
      _syncTracks();
      _scheduleEntries();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    _ticker.dispose();
    _mediaMs.dispose();
    super.dispose();
  }

  void _onPosition() {
    final positionMs = widget.position.value.inMicroseconds / 1000;
    final backwards = positionMs < _lastNativeMs;
    _lastNativeMs = positionMs;
    _sinceSampleMs = 0;
    // 正常回报的几毫秒误差不让文字倒退；回拖、暂停中的 seek 必须立即同步。
    _mediaMs.value =
        backwards || !widget.playing || !_tickerMode || !widget.enabled
        ? positionMs
        : math.max(positionMs, _mediaMs.value);
    _updateVisible();
    _syncTicker();
  }

  void _syncTicker() {
    final shouldTick =
        widget.enabled &&
        widget.playing &&
        _tickerMode &&
        _sinceSampleMs < _maxExtrapolationMs &&
        _flights.isNotEmpty &&
        _mediaMs.value < _flights.last.endMs;
    if (shouldTick && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final deltaMs = (elapsed - _lastTick).inMicroseconds / 1000;
    _lastTick = elapsed;
    final advanceMs = math.min(deltaMs, _maxExtrapolationMs - _sinceSampleMs);
    _sinceSampleMs += advanceMs;
    _mediaMs.value += advanceMs * _validRate(widget.rate);
    _updateVisible();
    _syncTicker();
  }

  void _scheduleEntries() {
    _entries = List.of(widget.entries);
    final sorted = List.of(_entries)
      ..sort((a, b) {
        final offset = a.offsetMs.compareTo(b.offsetMs);
        return offset == 0 ? a.id.compareTo(b.id) : offset;
      });
    final busyUntil = List<double>.filled(_tracks, double.negativeInfinity);
    // 官方公式 (横屏?12000:10000)/(DanmakuSpeed×播放器倍速)；倍速已经
    // 在媒体时钟里，这里再除以弹幕速度档。
    final flightMs =
        (widget.landscape ? _flightBaseMsLandscape : _flightBaseMs) /
        widget.settings.speed;
    final flights = <_DanmakuFlight>[];
    for (final entry in sorted) {
      final track = busyUntil.indexWhere((until) => until <= entry.offsetMs);
      if (track < 0) continue;
      final flight = _DanmakuFlight(entry, track, flightMs);
      busyUntil[track] = flight.endMs;
      flights.add(flight);
    }
    _flights = flights;
    _updateVisible(force: true, rebuild: false);
  }

  /// 生效轨道数：竖屏取设置的行数；横屏按显示区域密度折算
  /// （`vx1/b.java b():164-186` 的 rows = 屏高×占比/(行高+竖边距)）。
  /// MediaQuery 只能在 didChangeDependencies 之后查，所以走字段。
  void _syncTracks() {
    var tracks = widget.settings.lineCount;
    if (widget.landscape) {
      final tier = widget.settings.lineSpaceTier.clamp(1, 4);
      if (tier == 1) {
        tracks = 1;
      } else {
        final factor = DanmakuSettings.lineSpaceFactors[tier - 1];
        final height = MediaQuery.sizeOf(context).height;
        tracks = math.max(1, (height * factor / (_trackPitch + 4)).floor());
      }
    }
    _tracks = tracks;
  }

  void _updateVisible({bool force = false, bool rebuild = true}) {
    final now = _mediaMs.value;
    if (!force && now >= _visibleAtMs && now < _nextChangeMs) return;
    _visibleAtMs = now;
    _nextChangeMs = double.infinity;
    final visible = <_DanmakuFlight>[];
    for (final flight in _flights) {
      if (flight.entry.offsetMs > now) {
        _nextChangeMs = math.min(
          _nextChangeMs,
          flight.entry.offsetMs.toDouble(),
        );
        break;
      }
      if (now >= flight.endMs) continue;
      visible.add(flight);
      _nextChangeMs = math.min(_nextChangeMs, flight.endMs);
    }
    if (listEquals(_visible, visible)) return;
    _visible = visible;
    // 只有弹幕入场/离场才重建；中间每帧只更新 Flow 的绘制变换。
    if (rebuild) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.entries.isEmpty) {
      return const SizedBox.shrink();
    }
    // Flow 自带重绘边界，并缓存每条文字的子图层；不会逐帧重新排版文字。
    return IgnorePointer(
      child: Flow(
        delegate: _DanmakuFlowDelegate(_mediaMs, _visible),
        children: [for (final flight in _visible) _bubble(flight.entry)],
      ),
    );
  }

  Widget _bubble(PlayletComment entry) => Container(
    key: ValueKey('danmaku-${entry.id}'),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0x66000000),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      entry.text,
      maxLines: 1,
      // 官方字号/透明度来自 danmaku_config（DanmakuTextSize 5 档，
      // key_alpha 默认 255）。
      style: TextStyle(
        fontSize: widget.settings.fontSize,
        color: Color.fromRGBO(255, 255, 255, widget.settings.alpha / 255),
        shadows: const [Shadow(color: Colors.black54, blurRadius: 2)],
      ),
    ),
  );
}

class _DanmakuFlight {
  const _DanmakuFlight(this.entry, this.track, this.flightMs);

  final PlayletComment entry;
  final int track;

  /// 调度时刻的飞行时长；横竖屏切换会整批重排。
  final double flightMs;

  double get endMs => entry.offsetMs + flightMs;
}

class _DanmakuFlowDelegate extends FlowDelegate {
  _DanmakuFlowDelegate(this.mediaMs, this.flights) : super(repaint: mediaMs);

  final ValueListenable<double> mediaMs;
  final List<_DanmakuFlight> flights;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      const BoxConstraints();

  @override
  void paintChildren(FlowPaintingContext context) {
    for (var i = 0; i < flights.length; i++) {
      final flight = flights[i];
      final progress =
          (mediaMs.value - flight.entry.offsetMs) / flight.flightMs;
      if (progress < 0 || progress >= 1) continue;
      // 按真实文字宽度出屏，长弹幕不会在尾部仍可见时突然消失。
      final width = context.getChildSize(i)!.width;
      context.paintChild(
        i,
        transform: Matrix4.translationValues(
          context.size.width - progress * (context.size.width + width),
          8.0 + flight.track * _trackPitch,
          0,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_DanmakuFlowDelegate oldDelegate) =>
      oldDelegate.mediaMs != mediaMs ||
      !listEquals(oldDelegate.flights, flights);
}
