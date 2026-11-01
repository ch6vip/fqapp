import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/author_profile.dart';
import 'package:fqapp/pages/author_page.dart';
import 'package:fqapp/services/app_theme.dart' show einkModeNotifier;
import 'package:fqapp/widgets/home/home_back_button.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

/// 作者页视觉对齐：作品网格改用首页书架卡、AppBar 不再重复作者名、
/// 等级章跟随色板（墨水屏黑），返回键统一 HomeBackButton。
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

  testWidgets('作品用首页书架卡，副标题带字数', (tester) async {
    await pump(tester);

    expect(find.byType(HomeMediaCard), findsNWidgets(2));
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(
      grid.gridDelegate,
      isA<SliverGridDelegateWithFixedCrossAxisCount>(),
      reason: '与首页/搜索同一套 homeShelfDelegate，不再用旧的 140dp 自适应网格',
    );
    // word_number 之前没带进 MediaItem，卡片副标题因此缺字数。
    expect(find.text('11.6万字'), findsOneWidget);
  });

  testWidgets('AppBar 是「作者」，作者名只在头部出现一次', (tester) async {
    await pump(tester);

    expect(find.text('作者'), findsOneWidget);
    expect(find.text(_author.name), findsOneWidget);
  });

  testWidgets('返回键走 HomeBackButton 的 Lucide 箭头', (tester) async {
    await pump(tester);

    expect(find.byType(HomeBackButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(HomeBackButton),
        matching: find.byIcon(LucideIcons.chevron_left),
      ),
      findsOneWidget,
    );
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
