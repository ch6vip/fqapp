import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 墨水屏整屏刷新。
///
/// 首选厂商接口：封装原生通道 `fqapp/eink-refresh`，反射调用海信私有 EPD
/// 接口 `com.hmct.epd.EpdManager.forceClear()` 压残影，只在海信设备上生效。
///
/// Android 没有通用的 EPD 全刷公开 API（文石 Boox 的刷新由系统 E INK 控制
/// 中心按应用管理，不向第三方应用提供调用接口），所以非海信设备走软件
/// 回退：[flashRequest] +1，阅读页监听到后盖一张全屏白帧再撤掉——整帧
/// 变化会迫使绝大多数 EPD 控制器做一次全量（GC16）刷新，清掉残影。
/// 白闪是墨水屏阅读器的常见做法（KOReader 的全刷也是这个原理），代价是一
/// 次可见闪烁，只在厂商接口不可用时用。
class EinkRefreshService {
  static final EinkRefreshService instance = EinkRefreshService();

  static const _channel = MethodChannel('fqapp/eink-refresh');

  /// 设备是否提供海信 EPD 全刷接口。首次查询后缓存，避免每页翻页都过通道。
  bool? _supported;

  Future<bool> get supported async {
    if (_supported != null) return _supported!;
    try {
      _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      _supported = false;
    } on PlatformException {
      _supported = false;
    }
    return _supported!;
  }

  /// 若设备支持则调用一次整屏全刷，返回是否真正执行。调用异常（如系统服务
  /// 短暂不可用）按未执行处理，不打断阅读。
  Future<bool> refreshIfSupported() async {
    if (!await supported) return false;
    try {
      return await _channel.invokeMethod<bool>('refresh') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 软件白闪请求计数：每次 +1，阅读页监听到变化就盖一次全屏白帧。
  /// 只在厂商接口不可用时由 [requestRefresh] 触发。
  final ValueNotifier<int> flashRequest = ValueNotifier(0);

  /// 请求一次整屏刷新。海信设备走原生接口；其它设备走软件白闪回退。
  /// 任何异常都不抛，阅读流程不受影响。
  Future<void> requestRefresh() async {
    if (await supported) {
      await refreshIfSupported();
      return;
    }
    flashRequest.value++;
  }
}
