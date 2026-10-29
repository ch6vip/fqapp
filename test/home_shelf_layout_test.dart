import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';

/// 书架版式在页面层的回归：推荐页只画书、主视觉不重复、追加失败可重试。
///
/// 版式细节（卡片三行字、榜单名次、分区头）在 home_card_test.dart，这里只
/// 钉住页面组合与网络行为。
void main() {
  testWidgets('推荐页只画书：混排里的短剧不进书架', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    MediaItem item(String id, String title, String kind) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: kind,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: [
                      item('v1', '短剧一', 'video'),
                      item('b1', '小说一', 'book'),
                    ],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('小说一'), findsOneWidget);
    expect(find.text('短剧一'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有阅读史就没有继续阅读行，书全部落在网格里', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    MediaItem book(String id, String title, {String intro = ''}) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
      intro: intro,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: [
                      book('b1', '第一本'),
                      book('b2', '带简介的书', intro: '这段简介用来占住编辑位。'),
                    ],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    // 没有主视觉、也没有「今日之选」：两本书都按普通卡片落进网格。
    expect(find.text('今日之选'), findsNothing);
    expect(find.text('继续阅读'), findsNothing);
    expect(find.text('这段简介用来占住编辑位。'), findsNothing);
    expect(find.text('带简介的书'), findsOneWidget);
    expect(find.text('第一本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('追加失败给可点的重试，重试能继续拉下一页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    MediaItem book(String id, String title) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );
    var failNext = true;
    var nextCalls = 0;
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    if (tabType != 2) {
                      return const HomepagePage(
                        items: [],
                        nextOffset: null,
                        sessionId: null,
                      );
                    }
                    if (offset == 0) {
                      return HomepagePage(
                        items: [
                          for (var i = 0; i < 8; i++) book('b$i', '小说 $i'),
                        ],
                        nextOffset: 1,
                        sessionId: 's',
                      );
                    }
                    nextCalls++;
                    if (failNext) throw ApiException('网络开小差了');
                    return HomepagePage(
                      items: [book('later', '后来之书')],
                      nextOffset: null,
                      sessionId: 's',
                    );
                  },
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: MaterialApp(home: HomePage(scrollController: controller)),
      ),
    );
    await tester.pumpAndSettle();

    // 滚到底触发追加；这一页会失败。
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(nextCalls, 1);
    expect(find.text('加载失败，点击重试'), findsOneWidget);

    failNext = false;
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(nextCalls, 2);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('后来之书'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
