import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PortraitPlayer extends NativePlayer {
  @override
  int get videoWidth => 720;
  @override
  int get videoHeight => 1280;
}

void main() {
  for (final size in [const Size(1366, 768), const Size(1920, 1080)]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('portrait frame remains complete at $size, scale $scale', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = scale;
        SharedPreferences.setMockInitialValues({});
        final player = _PortraitPlayer();
        addTearDown(() async {
          debugDefaultTargetPlatformOverride = null;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await player.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: VideoPlayerChrome(
              player: player,
              title: '测试剧集',
              seriesTitle: '测试作品',
              episodes: [
                for (var i = 0; i < 10; i++)
                  Chapter(itemId: '$i', title: '第 $i 集', volumeName: ''),
              ],
              currentIndex: 0,
              duration: const Duration(minutes: 2),
              playing: false,
              enabled: false,
              onSelectEpisode: (_) async {},
              onError: (_) {},
              child: const ColoredBox(
                key: Key('portrait-frame'),
                color: Colors.red,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final picture = tester.getSize(find.byKey(const Key('portrait-frame')));
        expect(picture.width / picture.height, closeTo(9 / 16, .001));
        expect(picture.width, greaterThan(0));
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  Future<void> pumpChrome(
    WidgetTester tester, {
    required Size size,
    String synopsis = '',
    ValueChanged<int>? onWheelNavigate,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    SharedPreferences.setMockInitialValues({});
    final player = _PortraitPlayer();
    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await player.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerChrome(
          player: player,
          title: '测试剧集',
          seriesTitle: '测试作品',
          synopsis: synopsis,
          onWheelNavigate: onWheelNavigate,
          episodes: [
            for (var i = 0; i < 10; i++)
              Chapter(itemId: '$i', title: '第 $i 集', volumeName: ''),
          ],
          currentIndex: 0,
          duration: const Duration(minutes: 2),
          playing: false,
          enabled: false,
          onSelectEpisode: (_) async {},
          onError: (_) {},
          child: const ColoredBox(
            key: Key('portrait-frame'),
            color: Colors.red,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('wide window docks the catalog with synopsis; toggle collapses', (
    tester,
  ) async {
    await pumpChrome(
      tester,
      size: const Size(1366, 768),
      synopsis: '这是一段作品简介',
    );
    // 停靠面板在场：选集网格、简介、剧名（面板头部）；标题栏的剧名让位。
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('这是一段作品简介'), findsOneWidget);
    expect(find.text('测试作品'), findsOneWidget);
    expect(find.text('测试剧集'), findsNothing);
    expect(find.byTooltip('收起面板'), findsOneWidget);

    await tester.tap(find.byTooltip('收起面板'));
    await tester.pumpAndSettle();
    expect(find.text('选集'), findsNothing);
    expect(find.text('这是一段作品简介'), findsNothing);
    expect(find.text('测试剧集'), findsOneWidget);
    expect(find.byTooltip('展开面板'), findsOneWidget);

    await tester.tap(find.byTooltip('展开面板'));
    await tester.pumpAndSettle();
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('这是一段作品简介'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('narrow window keeps the catalog behind the dialog button', (
    tester,
  ) async {
    await pumpChrome(tester, size: const Size(900, 700), synopsis: '窄窗简介');
    expect(find.text('选集'), findsNothing);
    expect(find.text('窄窗简介'), findsNothing);
    expect(find.byTooltip('选集与作品信息'), findsOneWidget);
    expect(find.byTooltip('收起面板'), findsNothing);
    expect(find.byTooltip('展开面板'), findsNothing);
    expect(find.text('测试剧集'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('fullscreen shows neither the dock nor the title bar', (
    tester,
  ) async {
    DesktopPlatform.fullscreen.value = true;
    addTearDown(() => DesktopPlatform.fullscreen.value = false);
    await pumpChrome(
      tester,
      size: const Size(1366, 768),
      synopsis: '全屏简介',
    );
    expect(find.text('选集'), findsNothing);
    expect(find.text('全屏简介'), findsNothing);
    expect(find.byTooltip('返回'), findsNothing);
    expect(find.byTooltip('收起面板'), findsNothing);
    // 先退全屏再拆树，避免 dispose 走 window_manager 通道。
    DesktopPlatform.fullscreen.value = false;
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('wheel over the picture forwards ±1 to the host', (
    tester,
  ) async {
    final deltas = <int>[];
    await pumpChrome(
      tester,
      size: const Size(1366, 768),
      onWheelNavigate: deltas.add,
    );
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final center = tester.getCenter(find.byKey(const Key('portrait-frame')));
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 240)));
    await tester.pump();
    expect(deltas, [1]);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -240)));
    await tester.pump();
    expect(deltas, [1, -1]);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('wheel is inert when the host takes no navigation', (
    tester,
  ) async {
    await pumpChrome(tester, size: const Size(1366, 768));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.byKey(const Key('portrait-frame')))),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 240)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
