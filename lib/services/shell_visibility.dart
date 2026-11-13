import 'package:flutter/foundation.dart';

/// 壳层四个一级页面里「当前显示哪一个」。
///
/// 页面用它的变化来暂停/恢复播放器、取消定时器，但**不再依赖 `TickerMode`
/// 这个 InheritedWidget**。原因：`TickerMode.enabled` 翻转会让所有读过它的
/// 页面走一次 `didChangeDependencies` → 整页重建；真机日志里每次切底部 tab
/// 都跟着一次 50–280ms 的 UI 帧（dock 自身构建只要 0ms）。
///
/// `null` 表示没有壳层（单页测试、独立页面），按「可见」处理。
final ValueNotifier<int?> shellVisibleTab = ValueNotifier<int?>(null);

/// 复位成「没有壳层」（`null`），仅供测试使用。
///
/// [shellVisibleTab] 是进程级单例：测试里先 pump 了 `LazyIndexedStack`，
/// 后面的用例再直接 pump 单个页面时会读到残留下标而被判成「隐藏」，
/// 表现为分页定时器不启动、书架不补数据这类偶发失败。测试的 `setUp` /
/// `tearDown` 调一次即可。
@visibleForTesting
void resetShellVisibility() => shellVisibleTab.value = null;
