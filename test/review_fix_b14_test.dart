import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';
import 'package:fqapp/widgets/player/story_player_panel.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5}),
  );

  testWidgets('paused overlay fits a short video viewport', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 270));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = FakeNativePlayer(width: 1080, height: 1920);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
    await tester.pumpWidget(_chrome(player));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid relative seek taps accumulate the pending target', (
    tester,
  ) async {
    final gate = Completer<void>();
    final player = ControlledNativePlayer(seekGate: gate)..isPlaying = true;
    await player.create('https://example.invalid/1.mp4', '');
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
    await tester.pumpWidget(_chrome(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('快进10秒'));
    await tester.tap(find.byTooltip('快进10秒'));
    await tester.pump();
    expect(player.calls.where((call) => call.startsWith('seek:')).toList(), [
      'seek:10000ms',
      'seek:20000ms',
    ]);
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('related-work cards grow with large system text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final scale in [1.5, 2.0, 2.5]) {
      await tester.pumpWidget(
        _scaled(
          scale,
          AudioRelatedRow(
            works: const [
              RelatedWork(
                kind: 'book',
                id: 'b',
                title: '原著长篇小说标题',
                label: '原著小说',
              ),
              RelatedWork(
                kind: 'video',
                id: 'v',
                title: '改编短剧标题',
                label: '改编短剧',
              ),
            ],
            onTap: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'related at $scale');
    }
  });

  testWidgets('tone cards grow with large system text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final scale in [1.5, 2.0]) {
      await tester.pumpWidget(
        _scaled(
          scale,
          AudioToneSection(
            tones: const [
              AudioTone(
                id: 'a',
                title: '温柔女声',
                description: '自然流畅',
                badge: '升级',
              ),
              AudioTone(id: 'b', title: '沉稳男声', description: '声临其境'),
            ],
            selectedId: 'a',
            currentChapterTitle: '第一章 初入江湖',
            onSelect: (_) {},
            onReadAlong: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'tone at $scale');
    }
  });

  testWidgets('clearing the episode search re-locates the current episode', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final episodes = List.generate(
      71,
      (index) => Chapter(
        itemId: '${index + 1}',
        title: '第${index + 1}集',
        volumeName: '',
      ),
    );
    await tester.binding.setSurfaceSize(const Size(407, 904));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StoryPlayerPanel(
            scrollController: controller,
            episodes: episodes,
            currentIndex: 67,
            playingIndex: 67,
            title: '测试短剧',
            description: '',
            descriptionLoading: false,
            descriptionError: null,
            onRetryDescription: null,
            initialTab: 1,
            expanded: false,
            playing: true,
            onTabChanged: (_) {},
            onSelectEpisode: (_) {},
            onDragStart: (_) {},
            onDragUpdate: (_) {},
            onDragEnd: (_) {},
            onDragCancel: () {},
            onExpand: () {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_episode(67).hitTestable(), findsOneWidget);
    await tester.tap(find.text('找集'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('story-episode-search')),
      '68',
    );
    await tester.pumpAndSettle();
    expect(_episode(67).hitTestable(), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('story-episode-search')),
      '',
    );
    await tester.pumpAndSettle();
    expect(_episode(67).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Finder _episode(int index) => find.byKey(ValueKey('story-episode-$index'));

Widget _chrome(
  FakeNativePlayer player, {
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: VideoPlayerChrome(
    player: player,
    episodes: [
      Chapter(itemId: '1', title: '第一集', volumeName: ''),
      Chapter(itemId: '2', title: '第二集', volumeName: ''),
    ],
    currentIndex: 0,
    duration: player.duration,
    playing: player.isPlaying,
    onSelectEpisode: (index) async {},
    onError: (error) => throw error,
    child: const ColoredBox(color: Colors.black),
  ),
);

Widget _scaled(double scale, Widget child) => MaterialApp(
  builder: (context, view) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: view!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);
