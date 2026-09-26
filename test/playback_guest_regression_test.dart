import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_comment_panel.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('anonymous comments expose no unavailable editor', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletCommentPanel(
            seriesId: 'series-1',
            loader:
                ({
                  required sort,
                  required count,
                  required cursor,
                  required tag,
                }) async => const PlayletCommentPage(
                  comments: [PlayletComment(id: 'c1', text: '这集好看')],
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('这集好看'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('发布'), findsNothing);
  });

  testWidgets('disabling the lock config restores controls while locked', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    var lockEnabled = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _chrome(player, lockEnabled: lockEnabled);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('landscape-lock')));
    await tester.pump();
    expect(find.byKey(const ValueKey('landscape-play')), findsNothing);

    update(() => lockEnabled = false);
    await tester.pump();
    expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
    expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('disabling clear screen cannot strand an empty player', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    var reverse = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _chrome(player, reverse: reverse);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    expect(find.text('恢复'), findsOneWidget);
    update(() => reverse = true);
    await tester.pump();
    expect(find.byKey(const ValueKey('player-catalog-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-clear-screen')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
  testWidgets('a single tap within 800ms of a double tap cannot pause', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(MaterialApp(home: _chrome(player)));
    await tester.pumpAndSettle();
    final point = tester.getCenter(find.byKey(const ValueKey('video-surface')));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 400));
    expect(player.calls.where((call) => call == 'pause'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  for (final enabled in [false, true]) {
    testWidgets(
      'landscape double tap follows video_landscape_style_609 ($enabled)',
      (tester) async {
        final player = FakeNativePlayer()..isPlaying = true;
        await tester.pumpWidget(
          MaterialApp(home: _chrome(player, doubleTap: enabled)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
        await tester.pump();
        final point = tester.getCenter(
          find.byKey(const ValueKey('video-surface')),
        );
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          player.calls.where((call) => call == 'pause'),
          hasLength(enabled ? 1 : 0),
        );
        expect(
          find.byKey(const ValueKey('player-like-animation')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
      },
    );
  }

  testWidgets(
    'lock timeout requires waking the button and preserves video crop',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(
        MaterialApp(
          home: _chrome(
            player,
            lockEnabled: true,
            fillScreen: true,
            showSeekHint: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      final frame = tester.getRect(find.byKey(const ValueKey('video-frame')));
      final lock = find.byKey(const ValueKey('landscape-lock'));
      final position = tester.getRect(lock).center;
      await tester.tap(lock);
      await tester.pump(const Duration(seconds: 6));
      expect(tester.getRect(find.byKey(const ValueKey('video-frame'))), frame);
      expect(find.text('左右滑动可调整进度'), findsNothing);
      expect(lock.hitTestable(), findsNothing);
      await tester.tapAt(position);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('landscape-play')), findsNothing);
      expect(lock.hitTestable(), findsOneWidget);
      await tester.tap(lock);
      await tester.pump();
      expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets(
    'portrait fullscreen has no lock and rotation releases a landscape lock',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pumpWidget(
        MaterialApp(home: _chrome(player, lockEnabled: true)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pump();
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
      await tester.binding.setSurfaceSize(const Size(800, 450));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('landscape-lock')));
      await tester.pump();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
      expect(find.byKey(const ValueKey('player-catalog-bar')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );

  testWidgets('external overlays end long press and remove like animations', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    var blocked = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _chrome(player, blocked: blocked);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final point = tester.getCenter(find.byKey(const ValueKey('video-surface')));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byKey(const ValueKey('player-like-animation')), findsOneWidget);
    update(() => blocked = true);
    await tester.pump();
    expect(find.byKey(const ValueKey('player-like-animation')), findsNothing);
    update(() => blocked = false);
    await tester.pump();
    final gesture = await tester.startGesture(point);
    await tester.pump(const Duration(milliseconds: 700));
    expect(player.rate, 2);
    update(() => blocked = true);
    await tester.pump();
    expect(player.rate, 1);
    await gesture.up();
    expect(player.calls.where((call) => call == 'pause'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('landscape panels hide the lock until they close', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      MaterialApp(home: _chrome(player, lockEnabled: true)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('landscape-episodes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('landscape-lock')), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('landscape-lock')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('landscape-lock')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets(
    'legacy phone has only speed while pad has the icon clear action',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      await tester.pumpWidget(
        MaterialApp(home: _chrome(player, newStyle: false)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('player-legacy-actions')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-clear-screen')), findsNothing);
      await tester.pumpWidget(
        MaterialApp(home: _chrome(player, newStyle: false, padStyle: true)),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
      await tester.pump();
      expect(find.text('还原'), findsOneWidget);
      await tester.tap(find.text('还原'));
      await tester.pump();
      expect(find.byKey(const ValueKey('player-catalog-bar')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    },
  );
}

Widget _chrome(
  FakeNativePlayer player, {
  bool lockEnabled = false,
  bool reverse = false,
  bool doubleTap = false,
  bool blocked = false,
  bool fillScreen = false,
  bool showSeekHint = false,
  bool newStyle = true,
  bool padStyle = false,
}) => VideoPlayerChrome(
  player: player,
  title: '剧',
  episodes: [
    Chapter(itemId: 'v1', title: '第一集', volumeName: ''),
    Chapter(itemId: 'v2', title: '第二集', volumeName: ''),
  ],
  currentIndex: 0,
  duration: const Duration(minutes: 2),
  playing: true,
  shortSeries: true,
  landscapeLockEnabled: lockEnabled,
  landscapeDoubleTapEnabled: doubleTap,
  interactionBlocked: blocked,
  fillScreen: fillScreen,
  showSeekHint: showSeekHint,
  newPlayerBottomStyle: newStyle,
  padNewBottomStyle: padStyle,
  reverseClearScreen: reverse,
  onSelectEpisode: (_) async {},
  onError: (error) => throw error,
  child: const ColoredBox(color: Colors.black),
);
