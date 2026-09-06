import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5}),
  );

  testWidgets(
    '71 episodes use five columns and exact search selects the last episode',
    (tester) async {
      final fixture = await _mount(tester);
      final videoBefore = tester.getRect(
        find.byKey(const ValueKey('video-frame')),
      );
      final callsBefore = List<String>.of(fixture.player.calls);
      await _openEpisodes(tester);
      final panel = tester.getRect(find.byKey(const ValueKey('story-panel')));
      expect(panel.height, closeTo((904 - 39) * .55, 1));
      expect(find.byKey(const ValueKey('story-episode-grid')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('选集 · 71 集'), findsNothing);
      final first = tester.getRect(_episode(0));
      expect(tester.getRect(_episode(4)).top, closeTo(first.top, .1));
      expect(tester.getRect(_episode(5)).top, greaterThan(first.bottom));
      final viewport = tester.getRect(
        find.byKey(const ValueKey('story-episodes')),
      );
      final visible = find
          .byWidgetPredicate((widget) {
            final key = widget.key;
            return key is ValueKey<String> &&
                RegExp(r'^story-episode-\d+$').hasMatch(key.value);
          })
          .evaluate()
          .where((element) {
            final box = element.renderObject as RenderBox;
            final rect = box.localToGlobal(Offset.zero) & box.size;
            return rect.top >= viewport.top && rect.bottom <= viewport.bottom;
          })
          .length;
      expect(visible, greaterThanOrEqualTo(20));
      expect(fixture.player.calls, callsBefore);

      await tester.tap(find.byTooltip('展开面板'));
      await tester.pumpAndSettle();
      final toolbarTop = tester.getTopLeft(
        find.byKey(const ValueKey('story-episode-toolbar')),
      );
      await tester.drag(
        find.byKey(const ValueKey('story-episodes')),
        const Offset(0, -220),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('story-episode-toolbar'))),
        toolbarTop,
      );
      expect(fixture.selected, isEmpty);

      await tester.tap(find.text('找集'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('story-episode-search')),
        '71',
      );
      await tester.pumpAndSettle();
      expect(_episode(70), findsOneWidget);
      expect(_episode(0), findsNothing);
      await tester.tap(_episode(70));
      await tester.pumpAndSettle();
      expect(fixture.selected, [70]);
      expect(find.byKey(const ValueKey('story-panel')), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('video-frame'))),
        videoBefore,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(1080, 1920),
    const Size(1920, 1080),
    const Size(1080, 1080),
  ]) {
    testWidgets(
      'panel preserves aspect and playback for ${size.width} x ${size.height}',
      (tester) async {
        final fixture = await _mount(tester, videoSize: size);
        final before = tester.getRect(
          find.byKey(const ValueKey('video-frame')),
        );
        final callsBefore = List<String>.of(fixture.player.calls);
        final positionBefore = fixture.player.position;
        await _openEpisodes(tester);
        final panel = tester.getRect(find.byKey(const ValueKey('story-panel')));
        final video = tester.getRect(find.byKey(const ValueKey('video-frame')));
        expect(
          panel.height,
          closeTo((904 - 39) * (size.height > size.width ? .55 : .64), 1),
        );
        expect(
          video.width / video.height,
          closeTo(size.width / size.height, .001),
        );
        expect(video.bottom, lessThanOrEqualTo(panel.top + .1));
        expect(video.top, greaterThanOrEqualTo(39));
        await tester.tap(find.byTooltip('展开面板'));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const ValueKey('story-panel'))).top,
          closeTo(39, 1),
        );
        await tester.tap(find.byTooltip('收起面板'));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const ValueKey('story-panel'))).height,
          closeTo(panel.height, 1),
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('story-panel')), findsNothing);
        expect(
          tester.getRect(find.byKey(const ValueKey('video-frame'))),
          before,
        );
        expect(fixture.player.calls, callsBefore);
        expect(fixture.player.position, positionBefore);
        expect(fixture.player.isPlaying, true);
        expect(fixture.player.rate, 1.5);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'opening locates a late episode and closing search restores that location',
    (tester) async {
      await _mount(tester, currentIndex: 67);
      await _openEpisodes(tester);
      expect(_episode(67).hitTestable(), findsOneWidget);
      await tester.tap(find.text('找集'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('story-episode-search')),
        '999',
      );
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的剧集'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(_episode(67).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text uses four columns and search fits above the keyboard',
    (tester) async {
      await _mount(
        tester,
        window: const Size(320, 640),
        scale: const TextScaler.linear(2),
      );
      await _openEpisodes(tester);
      final first = tester.getRect(_episode(0));
      expect(tester.getRect(_episode(3)).top, closeTo(first.top, .1));
      expect(tester.getRect(_episode(4)).top, greaterThan(first.bottom));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('找集'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(
        bottom: 240 * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('story-episode-search')),
        '24',
      );
      await tester.pumpAndSettle();
      expect(_episode(23).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'meaningful episode titles retain their list and can be searched',
    (tester) async {
      final fixture = await _mount(
        tester,
        episodes: [
          Chapter(itemId: '1', title: '第1集 初次相遇', volumeName: ''),
          Chapter(itemId: '2', title: '第2集 久别重逢', volumeName: ''),
          Chapter(itemId: '3', title: '第3集 真相', volumeName: ''),
        ],
      );
      await _openEpisodes(tester);
      expect(find.byKey(const ValueKey('story-episode-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('story-episode-grid')), findsNothing);
      expect(find.text('第2集 久别重逢'), findsOneWidget);
      await tester.tap(find.text('找集'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('story-episode-search')),
        '重逢',
      );
      await tester.pumpAndSettle();
      await tester.tap(_episode(1));
      await tester.pumpAndSettle();
      expect(fixture.selected, [1]);
    },
  );

  testWidgets(
    'tab gestures keep controls fixed and a downward header drag closes the panel',
    (tester) async {
      final fixture = await _mount(tester);
      await _openEpisodes(tester);
      await tester.tap(find.text('简介'));
      await tester.pumpAndSettle();
      expect(find.text('这是测试短剧的真实简介内容'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('story-introduction')),
        const Offset(-160, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('story-episode-grid')), findsOneWidget);
      expect(fixture.selected, isEmpty);
      final handle = tester.getRect(
        find.byKey(const ValueKey('story-panel-drag')),
      );
      await tester.dragFrom(
        Offset(handle.center.dx, handle.top + 7),
        const Offset(0, 370),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('story-panel')), findsNothing);
      expect(fixture.selected, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final tab in ['introduction', 'episodes']) {
    testWidgets(
      'half panel scrolls $tab from its center without moving the sheet',
      (tester) async {
        final fixture = await _mount(tester, description: _longDescription);
        await _openEpisodes(tester);
        if (tab == 'introduction') {
          await tester.tap(find.text('简介'));
          await tester.pumpAndSettle();
        }
        final body = find.byKey(
          ValueKey(
            tab == 'introduction' ? 'story-introduction' : 'story-episodes',
          ),
        );
        final panel = find.byKey(const ValueKey('story-panel'));
        final before = tester.getRect(panel);
        final videoBefore = tester.getRect(
          find.byKey(const ValueKey('video-frame')),
        );
        final playerCalls = List<String>.of(fixture.player.calls);
        final scroll = _scrollPosition(tester, body);
        final heights = <double>[];
        final gesture = await tester.startGesture(tester.getCenter(body));
        for (var frame = 0; frame < 6; frame++) {
          await gesture.moveBy(const Offset(0, -30));
          await tester.pump(const Duration(milliseconds: 32));
          heights.add(tester.getSize(panel).height);
        }
        await gesture.up();
        await tester.pumpAndSettle();

        expect(heights, everyElement(closeTo(before.height, 1)));
        expect(scroll.pixels, greaterThan(100));
        final scrolled = scroll.pixels;
        await tester.drag(body, const Offset(0, 70));
        await tester.pumpAndSettle();
        expect(scroll.pixels, inExclusiveRange(0, scrolled));
        expect(tester.getRect(panel), before);
        expect(
          tester.getRect(find.byKey(const ValueKey('video-frame'))),
          videoBefore,
        );
        expect(fixture.selected, isEmpty);
        expect(fixture.player.calls, playerCalls);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('switching tabs keeps each content scroll position', (
    tester,
  ) async {
    await _mount(tester, description: _longDescription);
    await _openEpisodes(tester);
    await tester.tap(find.byTooltip('展开面板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简介'));
    await tester.pumpAndSettle();
    final introduction = find.byKey(const ValueKey('story-introduction'));
    await tester.drag(introduction, const Offset(0, -190));
    await tester.pumpAndSettle();
    final introOffset = _scrollPosition(tester, introduction).pixels;
    expect(introOffset, greaterThan(100));

    await tester.tap(find.text('选集'));
    await tester.pumpAndSettle();
    final episodes = find.byKey(const ValueKey('story-episodes'));
    await tester.drag(episodes, const Offset(0, -140));
    await tester.pumpAndSettle();
    final episodeOffset = _scrollPosition(tester, episodes).pixels;
    expect(episodeOffset, greaterThan(50));

    await tester.tap(find.text('简介'));
    await tester.pumpAndSettle();
    expect(
      _scrollPosition(tester, introduction).pixels,
      closeTo(introOffset, 1),
    );
    await tester.tap(find.text('选集'));
    await tester.pumpAndSettle();
    expect(_scrollPosition(tester, episodes).pixels, closeTo(episodeOffset, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('content drag does not snap back before the finger is released', (
    tester,
  ) async {
    await _mount(tester, description: _longDescription);
    await _openEpisodes(tester);
    await tester.tap(find.text('简介'));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('story-panel'));
    final body = find.byKey(const ValueKey('story-introduction'));
    final before = tester.getSize(panel).height;
    final gesture = await tester.startGesture(tester.getCenter(body));
    await gesture.moveBy(const Offset(0, 70));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 16));
    final during = tester.getSize(panel).height;
    await tester.pump(const Duration(milliseconds: 350));
    final held = tester.getSize(panel).height;
    await gesture.moveBy(const Offset(0, 35));
    await tester.pump(const Duration(milliseconds: 16));
    final moved = tester.getSize(panel).height;
    await gesture.up();
    await tester.pumpAndSettle();
    expect(during, lessThan(before - 20));
    expect(held, closeTo(during, 1));
    expect(moved, lessThan(held - 20));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expanded content collapses at its top and then scrolls at half height',
    (tester) async {
      await _mount(tester, description: _longDescription);
      await _openEpisodes(tester);
      await tester.tap(find.text('简介'));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('story-panel'));
      final restingHeight = tester.getSize(panel).height;
      final body = find.byKey(const ValueKey('story-introduction'));
      await tester.tap(find.byTooltip('展开面板'));
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, closeTo(904 - 39, 1));

      await tester.drag(body, const Offset(0, 260));
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, closeTo(restingHeight, 1));
      await tester.drag(body, const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, closeTo(restingHeight, 1));
      expect(_scrollPosition(tester, body).pixels, greaterThan(100));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('header expansion preserves the scrolled introduction', (
    tester,
  ) async {
    await _mount(tester, description: _longDescription);
    await _openEpisodes(tester);
    await tester.tap(find.text('简介'));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('story-panel'));
    final restingHeight = tester.getSize(panel).height;
    final body = find.byKey(const ValueKey('story-introduction'));
    await tester.drag(body, const Offset(0, -200));
    await tester.pumpAndSettle();
    final scrollOffset = _scrollPosition(tester, body).pixels;
    final handle = tester.getRect(
      find.byKey(const ValueKey('story-panel-drag')),
    );
    final gesture = await tester.startGesture(
      Offset(handle.center.dx, handle.top + 7),
    );
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -240));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, closeTo(904 - 39, 1));
    expect(_scrollPosition(tester, body).pixels, closeTo(scrollOffset, 1));

    await tester.tap(find.byTooltip('收起面板'));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, closeTo(restingHeight, 1));
    expect(_scrollPosition(tester, body).pixels, closeTo(scrollOffset, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a short introduction still allows a downward content fling to close',
    (tester) async {
      final fixture = await _mount(tester, description: '');
      await _openEpisodes(tester);
      await tester.tap(find.text('简介'));
      await tester.pumpAndSettle();
      final calls = List<String>.of(fixture.player.calls);
      await tester.fling(
        find.byKey(const ValueKey('story-introduction')),
        const Offset(0, 240),
        1500,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('story-panel')), findsNothing);
      expect(fixture.selected, isEmpty);
      expect(fixture.player.calls, calls);
      expect(tester.takeException(), isNull);
    },
  );
}

final _longDescription = List.filled(
  24,
  '主角重返故乡，从小城开始新的生活。在一次次选择中找回亲情和友谊，也逐渐揭开往事的真相。',
).join('\n');

ScrollPosition _scrollPosition(WidgetTester tester, Finder body) => tester
    .state<ScrollableState>(
      find.descendant(of: body, matching: find.byType(Scrollable)).first,
    )
    .position;

Finder _episode(int index) => find.byKey(ValueKey('story-episode-$index'));

Future<void> _openEpisodes(WidgetTester tester) async {
  await tester.tap(find.byTooltip('选集'));
  await tester.pumpAndSettle();
}

class _Fixture {
  final FakeNativePlayer player;
  final List<int> selected;
  _Fixture(this.player, this.selected);
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  Size window = const Size(407, 904),
  Size videoSize = const Size(1080, 1920),
  TextScaler scale = TextScaler.noScaling,
  int currentIndex = 0,
  String description = '这是测试短剧的真实简介内容',
  List<Chapter>? episodes,
}) async {
  await tester.binding.setSurfaceSize(window);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final player = FakeNativePlayer(
    width: videoSize.width.toInt(),
    height: videoSize.height.toInt(),
  )..isPlaying = true;
  final selected = <int>[];
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: scale,
          padding: const EdgeInsets.only(top: 39, bottom: 16),
        ),
        child: child!,
      ),
      home: VideoPlayerChrome(
        player: player,
        title: '测试短剧',
        episodes:
            episodes ??
            List.generate(
              71,
              (index) => Chapter(
                itemId: '${index + 1}',
                title: '第${index + 1}集',
                volumeName: '',
              ),
            ),
        currentIndex: currentIndex,
        playingIndex: currentIndex,
        playing: true,
        duration: player.duration,
        description: description,
        onSelectEpisode: (index) async => selected.add(index),
        onError: (error) => throw error,
        child: const ColoredBox(color: Colors.black),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(player, selected);
}
