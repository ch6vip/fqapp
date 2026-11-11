import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/desktop_platform.dart';

/// 桌面窗口失焦（`inactive`）只是没有输入焦点，窗口还在、渲染还在跑。
///
/// 之前阅读页把所有非 `resumed` 的状态都当「退到后台」，于是鼠标点到别的
/// 窗口，听书跟随就不再翻页了 —— 这个文件把判定锁住。
void main() {
  test('Linux lock and suspend overlap cannot resume on an early unlock', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final session = DesktopSystemSession.instance;
    session.accept({'type': 'locked', 'value': true});
    expect(playbackAppIsActive(AppLifecycleState.resumed), isFalse);
    session.accept({'type': 'suspend', 'value': true});
    session.accept({'type': 'locked', 'value': false});
    expect(desktopInactiveStillVisible(AppLifecycleState.resumed), isFalse);
    session.accept({'type': 'service', 'value': false});
    expect(session.suspended, isTrue);
    session.accept({'type': 'suspend', 'value': false});
    expect(playbackAppIsActive(AppLifecycleState.inactive), isTrue);
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('桌面三平台失焦仍算前台，最小化才算后台', () {
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        desktopInactiveStillVisible(AppLifecycleState.inactive),
        isTrue,
        reason: '$platform：失焦不该当成退到后台',
      );
      expect(
        desktopInactiveStillVisible(AppLifecycleState.resumed),
        isTrue,
        reason: '$platform：resumed 当然算前台',
      );
      expect(
        desktopInactiveStillVisible(AppLifecycleState.hidden),
        isFalse,
        reason: '$platform：窗口藏起来要停',
      );
      expect(
        desktopInactiveStillVisible(AppLifecycleState.paused),
        isFalse,
        reason: '$platform：挂起要停',
      );
    }
  });

  test('Windows and Linux video focus does not trigger background pause', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(playbackAppIsActive(AppLifecycleState.inactive), isTrue);
      expect(playbackAppIsActive(AppLifecycleState.hidden), isFalse);
      expect(playbackAppIsActive(AppLifecycleState.detached), isFalse);
    }
  });

  test('移动端失焦仍按后台处理（来电、下拉通知栏等打断）', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(desktopInactiveStillVisible(AppLifecycleState.inactive), isFalse);
    expect(desktopInactiveStillVisible(AppLifecycleState.resumed), isTrue);
  });
}
