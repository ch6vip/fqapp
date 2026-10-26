import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

/// 「边看边往后缓存」这一轮该排哪几集。
///
/// 纯函数，页面只负责触发时机、开关与网络判定 —— 范围算错会白下几集，
/// 所以这段单独抽出来测。
List<Chapter> autoCacheEpisodes({
  required List<Chapter> episodes,
  required int currentIndex,
  required int ahead,
}) {
  if (ahead <= 0 || episodes.isEmpty) return const [];
  final start = currentIndex + 1;
  if (start <= 0 || start >= episodes.length) return const [];
  final end = start + ahead > episodes.length
      ? episodes.length
      : start + ahead;
  return episodes.sublist(start, end);
}

/// 短剧「边看边往后缓存」的持久化设置。
///
/// 小说那边是阅读时预取前后各一章正文、缓存面板从当前章往后 20/50/100 章；
/// 短剧原来只有「播到哪集才去解析那集的地址」，离线连播必须先手动进缓存
/// 弹窗按 30 集一组勾选。这里存的就是补上这段的两个旋钮：
/// 往后缓存几集（0 = 关）、是否只在 Wi-Fi 下自动缓存。
class DramaCachePreferences {
  DramaCachePreferences._();

  static final DramaCachePreferences instance = DramaCachePreferences._();

  static const _aheadKey = 'drama_auto_cache_ahead';
  static const _wifiOnlyKey = 'drama_auto_cache_wifi_only';
  static const _heightKey = 'drama_download_max_height';

  /// 默认往后缓存 5 集。
  static const int defaultAhead = 5;

  /// 面板上可选的档位，0 = 关闭。
  static const List<int> presetAheads = [0, 3, 5, 10];

  /// 下载画质上限的可选档位；0 = 最高（不设上限）。
  ///
  /// 存的是「上限」而不是具体某一档：每集实际给了哪些档位由取流接口决定，
  /// 这里只能表达意图，具体挑哪档见 `DramaDownloader.pickVariant`。
  static const List<int> presetHeights = [0, 1080, 720, 480];

  /// 往后缓存几集；0 = 不自动缓存。
  final ValueNotifier<int> ahead = ValueNotifier<int>(defaultAhead);

  /// 下载画质上限（1080 / 720 / 480），0 = 最高。
  ///
  /// 手动缓存与自动往后缓存共用这一个值 —— 同一个「我最多接受多高」的意图，
  /// 分成两个开关只会让人不知道到底哪次生效。
  final ValueNotifier<int> downloadHeight = ValueNotifier<int>(0);

  /// 只在不计费链路（Wi-Fi / 以太网）下自动缓存。
  ///
  /// 短剧一集是整段 mp4，几十 MB，自动缓存默认必须避开移动流量 —— 手动
  /// 缓存有弹窗的流量提醒兜底，自动缓存没有，所以只能靠这条。
  final ValueNotifier<bool> wifiOnly = ValueNotifier<bool>(true);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final stored = sp.getInt(_aheadKey);
      ahead.value = stored == null
          ? defaultAhead
          : stored.clamp(0, 50);
      wifiOnly.value = sp.getBool(_wifiOnlyKey) ?? true;
      downloadHeight.value = sp.getInt(_heightKey) ?? 0;
    } catch (_) {
      // 偏好读不出来就用默认值：自动缓存错过的只是便利，不影响播放。
    }
  }

  Future<void> setAhead(int value) async {
    final next = value.clamp(0, 50);
    if (ahead.value == next) return;
    ahead.value = next;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_aheadKey, next);
    } catch (_) {
      // 存不下去只影响下次启动的默认值。
    }
  }

  Future<void> setWifiOnly(bool value) async {
    if (wifiOnly.value == value) return;
    wifiOnly.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_wifiOnlyKey, value);
    } catch (_) {}
  }

  Future<void> setDownloadHeight(int value) async {
    if (downloadHeight.value == value) return;
    downloadHeight.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_heightKey, value);
    } catch (_) {}
  }

  /// 忘掉已加载状态，让下一次 [load] 重新读 SharedPreferences。
  ///
  /// 只为测试存在：`_loaded` 是进程级一次性守卫，`setMockInitialValues`
  /// 换掉的初值不会被已加载过的实例重新读取。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    ahead.value = defaultAhead;
    wifiOnly.value = true;
    downloadHeight.value = 0;
  }
}
