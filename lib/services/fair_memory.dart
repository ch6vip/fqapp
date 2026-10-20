import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// 小米澎湃 OS 公平运行内存适配（原生侧 `FairMemoryPlugin` 的 Dart 对端）。
///
/// 系统在应用内存触达预警线时发 TRIM 广播，在触达查杀线时发 KILL 广播；
/// 原生侧转发到这里，处理完返回是否处理成功，原生侧再通过 Binder 回系统
/// （系统端超时 3 秒，原生侧 2.5 秒无回应会按“未处理”兜底回）。
///
/// - TRIM：只清内存里的解码图（Flutter `imageCache`）。磁盘缓存
///   （`PosterCache`）、章节缓存、播放器池都不动——磁盘缓存不清，下次读盘
///   还在；播放器池清了会打断正在播的；章节缓存清了要重下内容。
/// - KILL：跑登记的刷盘回调。阅读 / 漫画 / 播放页和听书控制器把各自的
///   `_persistProgress` 登记进来；各页平时已在翻页 / 定位变化时持续保存，
///   这里只是补“被杀前最后一刷”，避免丢最近几秒的进度。
///
/// 只在小米澎湃 OS 上生效：其他系统永远不发这两个广播，服务只是空转。
class FairMemoryService {
  static final FairMemoryService instance = FairMemoryService._();

  static const _channel = MethodChannel('fqapp/fair_memory');

  /// KILL 到达时需要刷盘的回调。注册返回注销函数，页面 dispose / 控制器
  /// 关闭时调用。回调内部错误会被隔离（记为未处理），不影响其他回调。
  final List<Future<void> Function()> _flushHandlers = [];

  /// Dart 侧 KILL 刷盘预算：必须在原生侧 2.5 秒兜底之前返回。
  Duration _flushTimeout = const Duration(seconds: 2);

  FairMemoryService._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// 强制构造单例并注册通道回调。`main()` 里调用；否则广播到达时 Dart 侧
  /// 还没有处理函数，原生侧只能按“未处理”回。
  void init() {}

  /// 注册 KILL 刷盘回调，返回注销函数。
  VoidCallback registerFlushHandler(Future<void> Function() handler) {
    _flushHandlers.add(handler);
    return () {
      _flushHandlers.remove(handler);
    };
  }

  @visibleForTesting
  void setFlushTimeoutForTest(Duration timeout) {
    _flushTimeout = timeout;
  }

  @visibleForTesting
  void clearFlushHandlersForTest() {
    _flushHandlers.clear();
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method != 'onMemoryWarning') return null;
    final args = call.arguments;
    if (args is! Map) return false;
    switch (args['kind']) {
      case 'trim':
        _releaseMemory();
        return true;
      case 'kill':
        return _flushState();
      default:
        return false;
    }
  }

  void _releaseMemory() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
  }

  Future<bool> _flushState() async {
    if (_flushHandlers.isEmpty) return true;
    final results = await Future.wait(
      _flushHandlers.map(
        (handler) async {
          try {
            await handler();
            return true;
          } catch (_) {
            return false;
          }
        },
      ),
    ).timeout(
      _flushTimeout,
      onTimeout: () => <bool>[false],
    );
    return results.every((handled) => handled);
  }
}
