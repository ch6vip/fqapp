import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/player/story_player_panel.dart';

/// F06 选集格子的状态、文案与角标用例。
///
/// 官方依据：
/// - 状态色 `hj3/r0.java:217-235,539-554`（选中/不可播/已看/普通）
/// - 文案 `hj3/r0.java:413-419`：预告 -> `epd`「预告」、
///   推荐流插入项 -> `esr`「高光」，其余是纯序号
/// - 「新」角标显示条件 `hj3/r0.java:539-554` 的 `T1`：
///   未选中 && 未播过 && 不在观看历史 && `isNewlyUpdate`
/// - 不可播集点击 Toast「该选集暂时无法播放」（`hj3/r0.java:598-601`）
void main() {
  test('tile state follows the official precedence', () {
    // 当前集优先于一切。
    expect(
      EpisodeTileState.of(current: true, watched: true, disabled: true),
      EpisodeTileState.current,
    );
    // 不可播优先于已看。
    expect(
      EpisodeTileState.of(current: false, watched: true, disabled: true),
      EpisodeTileState.disabled,
    );
    expect(
      EpisodeTileState.of(current: false, watched: true, disabled: false),
      EpisodeTileState.watched,
    );
    expect(
      EpisodeTileState.of(current: false, watched: false, disabled: false),
      EpisodeTileState.normal,
    );
  });

  test('tile colours match the APK resources', () {
    expect(EpisodeTileState.current.textColor, const Color(0xFFFA6725));
    expect(EpisodeTileState.current.backgroundColor, const Color(0x1AFA6725));
    expect(EpisodeTileState.current.weight, FontWeight.bold);
    expect(EpisodeTileState.watched.textColor, const Color(0x66000000));
    expect(EpisodeTileState.disabled.textColor, const Color(0x33000000));
    // 普通=浅色皮肤的 normal_light（skin_color_black_light=#FF000000）；
    // 深肤变体 #CCFFFFFF 配深色面板，本面板固定白底。
    expect(EpisodeTileState.normal.textColor, const Color(0xFF000000));
    expect(EpisodeTileState.normal.backgroundColor, const Color(0x08000000));
  });

  test('tile labels use the official trailer and highlight wording', () {
    expect(episodeTileLabel(index: 0), '1');
    expect(episodeTileLabel(index: 41), '42');
    expect(episodeTileLabel(index: 0, trailer: true), '预告');
    expect(episodeTileLabel(index: 5, highlight: true), '高光');
  });

  test('the new badge needs all four official conditions', () {
    bool shows({
      bool current = false,
      bool played = false,
      bool watched = false,
      bool newly = true,
    }) => episodeShowsNewBadge(
      current: current,
      played: played,
      watched: watched,
      newlyUpdate: newly,
    );
    expect(shows(), isTrue);
    expect(shows(current: true), isFalse);
    expect(shows(played: true), isFalse);
    expect(shows(watched: true), isFalse);
    expect(shows(newly: false), isFalse);
  });

  test('episodes parse the official flag fields', () {
    // 官方字段名来自 `EpisodeInfo.java` 的 @SerializedName：
    // is_preview_material（预告）/ is_newly_update（新）/ disable_play（不可播）。
    final episode = Episode.fromRaw({
      'item_id': 'v9',
      'is_preview_material': true,
      'disable_play': 1,
      'is_newly_update': 'true',
    }, index: 8);
    expect(episode.trailer, isTrue);
    expect(episode.disabled, isTrue);
    expect(episode.newlyUpdate, isTrue);
    final chapter = episode.toChapter();
    expect(chapter.trailer, isTrue);
    expect(chapter.disabled, isTrue);
    expect(chapter.newlyUpdate, isTrue);
  });

  test('the directory item_status also marks an episode as unplayable', () {
    final episode = Episode.fromRaw({'item_id': 'v1', 'item_status': 2}, index: 0);
    expect(episode.disabled, isTrue);
  });

  test('inserted-from-feed is never read from JSON', () {
    // 官方由客户端在插入推荐视频时自己 set（wp3/a.java:42、yw2/j.java:34），
    // 不是接口字段——所以「高光」只能来自客户端行为，不从回包猜。
    final episode = Episode.fromRaw({
      'item_id': 'v1',
      'is_inserted_from_feed': 1,
      'isInsertedFromFeed': true,
    }, index: 0);
    expect(episode.highlight, isFalse);
  });

  test('a playable episode stays enabled', () {
    final episode = Episode.fromRaw({'item_id': 'v1'}, index: 0);
    expect(episode.disabled, isFalse);
    expect(episode.trailer, isFalse);
    expect(episode.newlyUpdate, isFalse);
  });

  testWidgets('a disabled tile refuses to switch but says why', (tester) async {
    final selected = <int>[];
    final episodes = [
      Chapter(itemId: 'v1', title: '第 1 集', volumeName: '剧集'),
      Chapter(
        itemId: 'v2',
        title: '第 2 集',
        volumeName: '剧集',
        disabled: true,
      ),
      Chapter(
        itemId: 'v3',
        title: '第 3 集',
        volumeName: '剧集',
        newlyUpdate: true,
      ),
    ];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: StoryPlayerPanel(
              scrollController: scroll,
              episodes: episodes,
              currentIndex: 0,
              playingIndex: 0,
              playing: true,
              onSelectEpisode: selected.add,
              onDragStart: (_) {},
              onDragUpdate: (_) {},
              onDragEnd: (_) {},
              onDragCancel: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('story-episode-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(selected, isEmpty, reason: '不可播集不能切换');
    expect(find.text('该选集暂时无法播放'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('story-episode-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(selected, [2]);
  });

  testWidgets('the new badge only shows on the newly-updated tile', (
    tester,
  ) async {
    final episodes = [
      Chapter(itemId: 'v1', title: '第 1 集', volumeName: '剧集'),
      Chapter(
        itemId: 'v2',
        title: '第 2 集',
        volumeName: '剧集',
        newlyUpdate: true,
      ),
      Chapter(
        itemId: 'v3',
        title: '第 3 集',
        volumeName: '剧集',
        newlyUpdate: true,
      ),
    ];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: StoryPlayerPanel(
              scrollController: scroll,
              episodes: episodes,
              currentIndex: 0,
              playingIndex: 0,
              playing: true,
              // 第 2 集已在观看历史里 -> 按官方 T1 不该再挂「新」。
              watched: const {1},
              onSelectEpisode: (_) {},
              onDragStart: (_) {},
              onDragUpdate: (_) {},
              onDragEnd: (_) {},
              onDragCancel: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('story-episode-new-0')), findsNothing);
    expect(find.byKey(const ValueKey('story-episode-new-1')), findsNothing);
    expect(find.byKey(const ValueKey('story-episode-new-2')), findsOneWidget);
  });
}
