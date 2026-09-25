import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/widgets/player/story_player_panel.dart';

/// F06 剩余项：选集面板的**关联原著条**。
///
/// 官方依据（`a1.java:1819-1828`）：三个条件都要成立才显示——
/// 1) `series_relate_book_config_v659.relate_book_in_episodes_dialog`
///    （**默认 false**）；2) `videoRelateBook.bookInfo != null`；
/// 3) 不在 `SeriesDeliverUserRelateBookRevertV675` 的回滚实验里。
/// 布局节点是 `aa8.xml:17` 的 `gnh`（左右各 16dp）。
void main() {
  List<Chapter> episodes() => [
    for (var i = 0; i < 6; i++)
      Chapter(itemId: 'v$i', title: '第 ${i + 1} 集', volumeName: '剧集'),
  ];

  Future<void> pump(
    WidgetTester tester, {
    EpisodeRelateBook? relateBook,
    VoidCallback? onOpen,
  }) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: StoryPlayerPanel(
              scrollController: scroll,
              episodes: episodes(),
              currentIndex: 0,
              playingIndex: 0,
              playing: true,
              relateBook: relateBook,
              onOpenRelateBook: onOpen,
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
  }

  testWidgets('the relate-book row renders and reports its tap', (
    tester,
  ) async {
    var opens = 0;
    await pump(
      tester,
      relateBook: const EpisodeRelateBook(
        id: 'b1',
        title: '原著小说名',
      ),
      onOpen: () => opens++,
    );
    expect(
      find.byKey(const ValueKey('story-panel-relate-book')),
      findsOneWidget,
    );
    expect(find.text('原著小说名'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('story-panel-relate-book')));
    await tester.pump();
    expect(opens, 1);
  });

  testWidgets('no data means no row', (tester) async {
    await pump(tester);
    expect(
      find.byKey(const ValueKey('story-panel-relate-book')),
      findsNothing,
    );
  });

  testWidgets('without a callback the row has no arrow', (tester) async {
    await pump(
      tester,
      relateBook: const EpisodeRelateBook(id: 'b1', title: '原著小说名'),
    );
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  test('the official config gate defaults to off', () {
    // 官方 `relate_book_in_episodes_dialog` 默认 false：本地也默认关，
    // 不会在官方未显示的配置下强制添加这一条。
    expect(
      PlayerStyleConfig.defaults.relateBookInEpisodesDialog,
      isFalse,
    );
  });
}
