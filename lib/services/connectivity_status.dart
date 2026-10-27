import 'package:connectivity_plus/connectivity_plus.dart';

/// 当前网络形态的折叠视图：是否在线、是否计费链路（非 WiFi/以太网）。
/// 官方 `showWifiCheckDialog` 的启动门与 `onNetChangeCheck` 的运行中
/// 自动暂停都吃这两个布尔。
typedef ConnectivityView = ({bool online, bool metered});

ConnectivityView foldConnectivity(List<ConnectivityResult> results) {
  var online = false;
  var metered = false;
  for (final result in results) {
    if (result == ConnectivityResult.none) continue;
    online = true;
    if (result != ConnectivityResult.wifi &&
        result != ConnectivityResult.ethernet) {
      metered = true;
    }
  }
  return (online: online, metered: online && metered);
}

/// 当前网络形态；平台通道不可用时返回 null，表示「测不出来」。
///
/// 与 [currentConnectivity] 只差异常分支：手动下载入口宁可少问一次流量
/// 确认，也不能被误关死，所以那边把未知当成 Wi-Fi；而「边看边缓存」是
/// 无人确认的后台流量（一集几十 MB，没有任何提示），未知必须当成不是
/// Wi-Fi 跳过 —— 于是「测不出来」要和「确实在 Wi-Fi」区分得出来。
Future<ConnectivityView?> probeConnectivity() async {
  try {
    return foldConnectivity(await Connectivity().checkConnectivity());
  } catch (_) {
    return null;
  }
}

Future<ConnectivityView> currentConnectivity() async =>
    await probeConnectivity() ?? (online: true, metered: false);
