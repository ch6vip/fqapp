/// 短剧弹幕层：取数、时间轴渲染、开关与发送。
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
/// 渲染时长、行高、透明度等渲染参数**未取证**，本层只保证官方已证的
/// 时间轴语义与文案，视觉参数是本地的。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/playlet_comment.dart';

/// 同时出现在屏幕上的弹幕行数（本地取值，官方行数配置未取证）。
const _trackCount = 4;

/// 一条弹幕在屏幕上飞过的时长（官方基准值 10000ms / 倍速，
/// container/l.java:1366-1380）。
const _flightBaseMs = 10000.0;

/// 官方弹幕单条上限（`VideoDanmakuSettingConfig` 的 `danmakuTextMaxLength`，
/// 上限值本身随服务端下发，本地取官方默认文案里的常见值 50）。
const danmakuMaxLength = 50;

/// 飞行时长（供渲染层与用例共用）。
double danmakuFlightMs(double rate) =>
    _flightBaseMs / (rate <= 0 ? 1 : math.max(rate, 0.1));

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
class DanmakuTimeline {
  final List<PlayletComment> entries = [];
  bool _loaded = false;

  bool get isEmpty => entries.isEmpty;

  /// 切集：官方清时间线整池重灌（container/l.java:1496-1528）。
  void reset() {
    entries.clear();
    _loaded = false;
  }

  /// 装填一页；同一集重复装填按 id 去重（官方按 vid 整池替换）。
  void load(List<PlayletComment> page, {bool replace = false}) {
    if (replace) entries.clear();
    final seen = entries.map((e) => e.id).toSet();
    for (final entry in page) {
      if (seen.add(entry.id)) entries.add(entry);
    }
    entries.sort((a, b) => a.offsetMs.compareTo(b.offsetMs));
    _loaded = true;
  }

  /// 某时刻应该显示的弹幕（毫秒坐标；倍速只改飞行时长，不重取数）。
  List<PlayletComment> visibleAt(int nowMs, {double rate = 1}) {
    final flight = danmakuFlightMs(rate);
    return [
      for (final entry in entries)
        if (nowMs - entry.offsetMs >= 0 && nowMs - entry.offsetMs <= flight)
          entry,
    ];
  }

  /// 拖动进度后需要重新装填（官方 seekTo() 清游标）。
  bool get needsReload => !_loaded;
}

/// 从上游响应取出弹幕时间轴。
///
/// 官方回包的时间字段名**未取证**（F04 取证报告未取证第 11 条），这里按已证实的
/// 发送侧字段名 offset（毫秒）读取；读不到时保持 0，会在片头出现。
List<PlayletComment> danmakuFromPage(PlayletCommentPage page) =>
    List<PlayletComment>.unmodifiable(page.comments);

/// 弹幕渲染层：按当前进度把时间轴上的弹幕画到屏幕上。
class PlayletDanmakuLayer extends StatefulWidget {
  const PlayletDanmakuLayer({
    super.key,
    required this.entries,
    required this.position,
    this.rate = 1,
    this.enabled = true,
  });

  /// 当前时间轴上的弹幕（毫秒坐标）。
  final List<PlayletComment> entries;

  /// 播放进度；由外层用 ValueListenable 驱动，避免每帧重建整个 chrome。
  final ValueListenable<Duration> position;
  final double rate;

  /// 官方开关；关闭时整层不渲染。
  final bool enabled;

  @override
  State<PlayletDanmakuLayer> createState() => _PlayletDanmakuLayerState();
}

class _PlayletDanmakuLayerState extends State<PlayletDanmakuLayer> {
  @override
  void initState() {
    super.initState();
    widget.position.addListener(_onPosition);
  }

  @override
  void didUpdateWidget(PlayletDanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.position, widget.position)) {
      oldWidget.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    super.dispose();
  }

  void _onPosition() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.entries.isEmpty) {
      return const SizedBox.shrink();
    }
    final nowMs = widget.position.value.inMilliseconds;
    final flight = danmakuFlightMs(widget.rate);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width <= 0) return const SizedBox.shrink();
        final shown = <Widget>[];
        final busyUntil = List<double>.filled(_trackCount, -1);
        for (final entry in widget.entries) {
          final elapsed = nowMs - entry.offsetMs;
          if (elapsed < 0 || elapsed > flight) continue;
          var track = -1;
          for (var i = 0; i < _trackCount; i++) {
            if (busyUntil[i] <= entry.offsetMs) {
              track = i;
              busyUntil[i] = entry.offsetMs + flight;
              break;
            }
          }
          if (track < 0) continue;
          final progress = elapsed / flight;
          shown.add(
            Positioned(
              top: 8.0 + track * 28,
              left: width - progress * (width + 120),
              child: _bubble(entry),
            ),
          );
        }
        return IgnorePointer(
          child: ClipRect(child: Stack(children: shown)),
        );
      },
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
      style: const TextStyle(
        fontSize: 14,
        color: Colors.white,
        shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
      ),
    ),
  );
}
