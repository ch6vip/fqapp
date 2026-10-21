import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
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
}
