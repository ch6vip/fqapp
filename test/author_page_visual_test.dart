import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/author_profile.dart';
import 'package:fqapp/pages/author_page.dart';
import 'package:fqapp/services/app_theme.dart' show einkModeNotifier;
import 'package:fqapp/widgets/detail/detail_archive.dart';
import 'package:fqapp/widgets/home/home_back_button.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

/// 作者页视觉对齐：作品改成上游 `NovelRow` 式行（序档案头 + 封面 + 标题 /
/// 元信息），头栏走 `ArchiveFeaturePage`，作者名只在头部出现一次，
/// 等级章跟随色板（墨水屏黑）。
const _author = AuthorProfile(
  id: '1988336383174046',
  name: '七彩虹桥的吕师傅',
  description: '人生是旷野呀朋友！',
  level: '作家Lv.5',
  followerCount: 20905,
  workCount: 5,
  works: [
    AuthorWork(
      id: '7676082357077543960',
      title: '发现青梅真香且喜欢我，我重生了',
      abstract: '【轻松校园】',
      category: '都市脑洞',
      creationStatus: 1,
      wordNumber: 115815,
    ),
    AuthorWork(
      id: '7491705400958405694',
      title: '霸凌？穿书黄毛！学霸也是霸！',
      category: '都市脑洞',
      creationStatus: 0,
      wordNumber: 1328318,
    ),
  ],
);

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: AuthorPage(
          authorId: _author.id,
          fallbackName: _author.name,
          loader: (_) async => _author,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('作品用上游档案行，副标题带字数', (tester) async {
    await pump(tester);

    expect(
      find.byKey(const ValueKey('author_work_7676082357077543960')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('author_work_7491705400958405694')),
      findsOneWidget,
    );
    expect(find.byType(HomeMediaCard), findsNothing);
    expect(find.byType(SliverGrid), findsNothing);
    // word_number 带进 META 行，字数出现在作品行里。
    expect(find.textContaining('11.6万字'), findsOneWidget);
    // Upstream NovelRow 的档案编号行。作者行省略：整页就是该作者的作品。
    expect(
      find.text(detailArchiveFileCode('7676082357077543960')),
      findsOneWidget,
    );
  });

  testWidgets('下拉刷新会重新加载作者资料', (tester) async {
    var calls = 0;
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: AuthorPage(
          authorId: _author.id,
          fallbackName: _author.name,
          loader: (_) async {
            calls++;
            return _author;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.fling(
      find.byKey(const Key('author_scroll')),
      const Offset(0, 320),
      1000,
    );
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('头栏是「作者作品」，作者名只在头部出现一次', (tester) async {
    await pump(tester);

    expect(find.text('作者作品'), findsOneWidget);
    expect(find.text(_author.name), findsOneWidget);
  });

  testWidgets('返回键走共享的 GlassIconButton', (tester) async {
    await pump(tester);

    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.byType(HomeBackButton), findsNothing);
  });

  testWidgets('墨水屏等级章白底黑字黑描边', (tester) async {
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    await pump(tester);

    final level = tester.widget<Text>(find.text('作家Lv.5'));
    expect(level.style?.color, Colors.black);
    final chip = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('作家Lv.5'),
            matching: find.byType(Container),
          ),
        )
        .firstWhere(
          (container) =>
              (container.decoration as BoxDecoration?)?.borderRadius ==
              BorderRadius.circular(4),
        );
    final decoration = chip.decoration! as BoxDecoration;
    expect(decoration.color, Colors.white);
    expect((decoration.border! as Border).top.color, Colors.black);
  });
}
