import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

/// Records the orientation requests the player makes.
class _OrientationLog {
  final List<List<String>> requests = [];

  /// The most recent request, or null when none was made.
  List<String>? get last => requests.isEmpty ? null : requests.last;

  bool get pinnedPortraitOnly =>
      last != null &&
      last!.isNotEmpty &&
      last!.every((value) => value.startsWith('DeviceOrientation.portrait'));

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          final arguments = call.arguments;
          if (arguments is List) {
            requests.add(arguments.map((value) => '$value').toList());
          }
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'player_playback_rate': 1.0}),
  );

  testWidgets('an episode change never forces portrait', (tester) async {
    // The reported bug: playing a landscape episode fullscreen, the next
    // episode auto-plays and the picture snaps back to portrait. The new player
    // reports no video size yet, and "0 > 0 is false, so portrait" was the
    // cause.
    final orientations = _OrientationLog()..install(tester);
    final first = FakeNativePlayer(width: 1920, height: 1080);
    final second = FakeNativePlayer(width: 0, height: 0);

    await tester.pumpWidget(_app(first));
    await tester.pumpAndSettle();

    // Go fullscreen: a known landscape video pins landscape.
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    expect(orientations.last, isNotNull);
    expect(orientations.pinnedPortraitOnly, isFalse);

    // Auto-advance hands over to a freshly created player of unknown size.
    await tester.pumpWidget(_app(second));
    await tester.pumpAndSettle();
    expect(
      orientations.pinnedPortraitOnly,
      isFalse,
      reason: 'an unknown video size must not be read as portrait',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await first.dispose();
    await second.dispose();
  });

  testWidgets('the real orientation is applied once the size arrives', (
    tester,
  ) async {
    final orientations = _OrientationLog()..install(tester);
    // Starts unknown, exactly like a player created for the next episode.
    final player = FakeNativePlayer(width: 0, height: 0);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    // Nothing pinned yet: the device keeps whatever it is using.
    expect(orientations.last, isNull);

    // The size arrives; fullscreen must adopt the video's orientation.
    player.width = 1920;
    player.height = 1080;
    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    expect(orientations.last, isNotNull);
    expect(
      orientations.last!.every(
        (value) => value.startsWith('DeviceOrientation.landscape'),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('a portrait video pins portrait', (tester) async {
    final orientations = _OrientationLog()..install(tester);
    final player = FakeNativePlayer(width: 1080, height: 1920);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    expect(orientations.pinnedPortraitOnly, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('leaving fullscreen releases the orientation', (tester) async {
    final orientations = _OrientationLog()..install(tester);
    final player = FakeNativePlayer(width: 1920, height: 1080);

    await tester.pumpWidget(_app(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    // An empty list means "follow the device again".
    expect(orientations.last, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
}

Widget _app(FakeNativePlayer player) => MaterialApp(
  home: VideoPlayerChrome(
    player: player,
    episodes: [
      Chapter(itemId: '1', title: '第一集', volumeName: ''),
      Chapter(itemId: '2', title: '第二集', volumeName: ''),
    ],
    currentIndex: 0,
    duration: player.duration,
    playing: true,
    onSelectEpisode: (index) async {},
    onError: (error) => throw error,
    child: const ColoredBox(color: Colors.black),
  ),
);
