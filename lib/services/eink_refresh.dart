import 'package:flutter/services.dart';

/// 海信墨水屏整屏刷新桥。封装原生通道 `fqapp/eink-refresh`，反射调用厂商
/// 私有 EPD 接口 `com.hmct.epd.EpdManager.forceClear()` 压残影。
///
/// 只在海信墨水屏设备（提供该隐藏接口）上真正生效；其它平台/设备
/// [supported] 返回 false，[refreshIfSupported] 直接跳过，不会抛错。
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
}
