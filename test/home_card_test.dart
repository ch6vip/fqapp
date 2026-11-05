import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/app_theme.dart' show einkModeNotifier;
import 'package:fqapp/widgets/home/home_archive.dart';
import 'package:fqapp/widgets/home/home_cell_blocks.dart';
import 'package:fqapp/widgets/home/home_rank_shelf.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_reading_row.dart';
import 'package:fqapp/widgets/home/home_shelf.dart';

/// 首页卡片的版式回归。
///
/// 首页重做后卡片只剩三行字：书名、作者/推荐理由/评分。这里钉住三件容易被
/// 后续改动悄悄改回去的事：书卡不再有白色卡面和封面角标、推荐理由不再画成
/// 彩色 chip、榜单的名次是真实名次而不是装饰序号。
void main() {
  MediaItem book({
    String id = 'b1',
    String title = '书一',
    String author = '',
    String kind = 'book',
    String ep = '',
    String intro = '',
    double? score,
    MediaTag? tag,
    List<String> rankTags = const [],
    List<MediaRecTag> recTags = const [],
    int creationStatus = -1,
  }) => MediaItem(
    id: id,
    title: title,
    cover: '',
    author: author,
    badge: '',
    ep: ep,
    kind: kind,
    intro: intro,
    score: score,
    tag: tag,
    rankTags: rankTags,
    recTags: recTags,
    creationStatus: creationStatus,
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  group('HomeMediaCard', () {
    testWidgets('is cover + two-line title + one meta line, no white card', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 160,
          child: HomeMediaCard(
            item: book(title: '一个非常非常长的书名用来验证它占两行', author: '某作者', score: 9.3),
            onTap: () {},
          ),
        ),
      );

      final title = tester.widget<Text>(find.text('一个非常非常长的书名用来验证它占两行'));
      expect(title.maxLines, 2);
      expect(title.style!.fontSize, 15);
      expect(title.style!.fontWeight, FontWeight.w600);

      // 作者、评分同一行灰字，中间用分隔点；评分不再是封面上的白色角标。
      final meta = tester.widget<Text>(find.text('某作者 · 9.3分'));
      expect(meta.maxLines, 1);
      expect(meta.style!.fontSize, 11);
      expect(meta.style!.color, const HomePalette(false).muted);
    });

    testWidgets('carries the recommend reason as text, not a coloured chip', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 160,
          child: HomeMediaCard(
            item: book(
              recTags: const [
                MediaRecTag(
                  text: '16个老书虫在看',
                  textColor: '#D7A461FF',
                  bgColor: '#D7A4611A',
                ),
              ],
            ),
            onTap: () {},
          ),
        ),
      );

      final tag = tester.widget<Text>(find.text('16个老书虫在看'));
      // 理由退到灰色副标题里，不再用服务端的番茄金配色。
      expect(tag.style!.color, const HomePalette(false).muted);
      expect(find.byKey(const Key('home_card_tag')), findsNothing);
    });

    testWidgets(
      'keeps the upstream badge on the cover and drops the kind chip',
      (tester) async {
        await pump(
          tester,
          SizedBox(
            width: 160,
            child: HomeMediaCard(
              item: book(
                tag: const MediaTag(text: '上新', lightColors: ['#00B876']),
              ),
              onTap: () {},
            ),
          ),
        );

        expect(find.byKey(const Key('home_card_tag')), findsOneWidget);
        expect(find.text('上新'), findsOneWidget);
        // 分类标签只在非书卡片缺信息时兜底，书卡上不再重复「小说」。
        expect(find.text(homeKindLabel('book')), findsNothing);
      },
    );

    testWidgets('shows the episode count on a video cover', (tester) async {
      await pump(
        tester,
        SizedBox(
          width: 160,
          child: HomeMediaCard(
            item: book(kind: 'video', ep: '第12集'),
            onTap: () {},
          ),
        ),
      );

      expect(find.text('第12集'), findsOneWidget);
    });

    testWidgets('drops the score when the payload has none', (tester) async {
      await pump(
        tester,
        SizedBox(
          width: 160,
          child: HomeMediaCard(item: book(), onTap: () {}),
        ),
      );

      expect(find.text('暂无评分'), findsNothing);
      expect(find.textContaining('分'), findsNothing);
    });

    testWidgets('a missing cover falls back to the archive title block', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 160,
          child: HomeMediaCard(
            item: book(title: '断图之书', author: '某人'),
            onTap: () {},
          ),
        ),
      );

      // 旧兜底是圆环 + Lucide 图标；现在是渐变块上的竖排书名，没有图标。
      expect(
        find.descendant(
          of: find.byType(HomeMediaCard),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(HomeMediaCard),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
    });

    testWidgets('e-ink covers turn greyscale and get a black outline', (
      tester,
    ) async {
      final original = einkModeNotifier.value;
      einkModeNotifier.value = true;
      addTearDown(() => einkModeNotifier.value = original);
      await pump(
        tester,
        SizedBox(
          width: 160,
          child: StoryCover(item: book(title: '灰度书'), cacheWidth: 320),
        ),
      );

      final filtered = tester.widget<ColorFiltered>(
        find.descendant(
          of: find.byType(StoryCover),
          matching: find.byType(ColorFiltered),
        ),
      );
      expect(filtered.colorFilter, einkCoverFilter);
      // 过滤矩阵不能退化成恒等矩阵（否则彩色封面照样显示）。
      expect(
        einkCoverFilter,
        isNot(
          const ColorFilter.matrix(<double>[
            1, 0, 0, 0, 0, //
            0, 1, 0, 0, 0, //
            0, 0, 1, 0, 0, //
            0, 0, 0, 1, 0, //
          ]),
        ),
      );
      final outline = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(StoryCover),
          matching: find.byType(DecoratedBox),
        ),
      );
      final border = (outline.decoration as BoxDecoration).border!;
      expect(border.top.color, Colors.black);
      expect(border.top.width, 1);
    });

    testWidgets('colour covers have neither the e-ink filter nor outline', (
      tester,
    ) async {
      final original = einkModeNotifier.value;
      einkModeNotifier.value = false;
      addTearDown(() => einkModeNotifier.value = original);
      await pump(
        tester,
        SizedBox(
          width: 160,
          child: StoryCover(item: book(title: '彩色书'), cacheWidth: 320),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(StoryCover),
          matching: find.byType(ColorFiltered),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(StoryCover),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
    });
  });

  test('archive styles use the bundled font families', () {
    final serif = homeSerifStyle(size: 15, color: Colors.white);
    expect(serif.fontFamily, 'Home Serif');
    expect(serif.fontWeight, FontWeight.w700);
    final code = homeCodeStyle(const HomePalette(false));
    expect(code.fontFamily, 'Home Mono');
    expect(code.fontWeight, FontWeight.w500);
  });

  group('HomeContinueRow', () {
    testWidgets('is one line: action, book · chapter, percent, close', (
      tester,
    ) async {
      var taps = 0;
      await pump(
        tester,
        SizedBox(
          width: 368,
          child: HomeContinueRow(
            now: ReadingNow(
              item: book(title: '在读的书'),
              verb: '继续阅读',
              detail: '读到 第32章',
              progress: 0.78,
            ),
            onOpen: () => taps++,
            onDismiss: () {},
          ),
        ),
      );

      // 档案条：编号行写动作与进度章节，书名单独一行，右端百分比。
      expect(find.text('CONTINUE / 读到 第32章'), findsOneWidget);
      expect(find.text('在读的书'), findsOneWidget);
      expect(find.text('78%'), findsOneWidget);

      await tester.tap(find.text('在读的书'));
      expect(taps, 1);
    });

    testWidgets('the close button hides the row without opening the book', (
      tester,
    ) async {
      var opened = 0;
      var dismissed = 0;
      await pump(
        tester,
        SizedBox(
          width: 368,
          child: HomeContinueRow(
            now: ReadingNow(
              item: book(title: '在读的书'),
              verb: '继续阅读',
              detail: '读到 第32章',
              progress: 0.5,
            ),
            onOpen: () => opened++,
            onDismiss: () => dismissed++,
          ),
        ),
      );

      await tester.tap(find.byIcon(LucideIcons.x));
      expect(dismissed, 1);
      expect(opened, 0);
    });

    testWidgets('drops the percent when there is no progress', (tester) async {
      await pump(
        tester,
        SizedBox(
          width: 368,
          child: HomeContinueRow(
            now: ReadingNow(
              item: book(title: '在读的书'),
              verb: '继续阅读',
              detail: '上次阅读',
              progress: 0,
            ),
            onOpen: () {},
            onDismiss: () {},
          ),
        ),
      );

      expect(find.textContaining('%'), findsNothing);
      expect(find.text('CONTINUE / 上次阅读'), findsOneWidget);
      expect(find.text('在读的书'), findsOneWidget);
    });

    test('fromHistory turns an audiobook entry into listen wording', () {
      final now = ReadingNow.fromHistory({
        'id': 'a1',
        'title': '在听的书',
        'kind': 'audio',
        'lastChapterTitle': '第9集',
        'progress': 0.4,
      });
      expect(now.verb, '继续收听');
      expect(now.detail, '听到 第9集');
      expect(now.progress, closeTo(0.4, 1e-9));
      expect(now.item.id, 'a1');
    });
  });

  group('HomeSectionHeader', () {
    testWidgets('is a bare title with an optional trailing action', (
      tester,
    ) async {
      await pump(
        tester,
        const SizedBox(
          width: 368,
          child: HomeSectionHeader(
            title: '为你推荐',
            action: SizedBox(width: 10, height: 10),
          ),
        ),
      );

      final title = tester.widget<Text>(find.text('为你推荐'));
      expect(title.style!.fontSize, 19);
      expect(title.style!.fontWeight, FontWeight.w700);
      expect(find.text('更多'), findsNothing);
    });
  });

  group('HomeRankCell rail', () {
    HomeCell cellWith(List<MediaItem> books) => HomeCell(
      showType: 511,
      name: '排行榜',
      id: '',
      style: const {},
      items: const [],
      children: [
        for (final item in books)
          HomeCell(
            showType: 512,
            name: '',
            id: '',
            style: const {},
            items: [item],
            children: const [],
          ),
      ],
    );

    testWidgets('pages through the real rank order', (tester) async {
      await pump(
        tester,
        HomeRankCell(
          cell: cellWith([
            for (var i = 1; i <= 4; i++) book(id: 'b$i', title: '榜书$i'),
          ]),
          onOpen: (_) {},
          onMore: () {},
        ),
      );

      expect(find.text('排行榜'), findsOneWidget);
      expect(find.byType(HomeRankShelf), findsOneWidget);
      // 书架下面的信息行和翻页器跟着当前那本走。
      expect(find.text('01 / 04'), findsOneWidget);
      expect(find.text('榜书1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('home_rank_next')));
      await tester.pumpAndSettle();
      expect(find.text('02 / 04'), findsOneWidget);
      expect(find.text('榜书2'), findsOneWidget);
    });

    testWidgets('puts author and status under the title', (tester) async {
      await pump(
        tester,
        HomeRankCell(
          cell: cellWith([
            book(
              title: '榜书一',
              author: '云中客',
              creationStatus: 1,
              rankTags: const ['多人二刷', '9320万热度'],
            ),
          ]),
          onOpen: (_) {},
          onMore: () {},
        ),
      );

      final subtitle = tester.widget<Text>(find.text('云中客 · 连载中'));
      expect(subtitle.maxLines, 1);
      // e615e2b 给档案控件减重：标题 19→17、信息行 12.5→12、行高 1.3→1.4。
      expect(subtitle.style!.fontSize, 12);
      expect(subtitle.style!.height, 1.4);
      // 信息行换成「作者 · 状态」，榜首标签和评分不再重复堆在这里。
      expect(find.text('多人二刷'), findsNothing);
    });
  });

  test('parseRecTags reads content and server colours', () {
    final tags = parseRecTags([
      {
        'content': '16个老书虫在看',
        'rec_reason_style': {
          'rec_style_text_color': '#D7A461FF',
          'rec_style_background_color': '#D7A4611A',
          'rec_style_dark_text_color': '#A8804CFF',
          'rec_style_dark_background_color': '#A8804C33',
        },
      },
      {'content': ''},
      'not-a-map',
    ]);
    expect(tags, hasLength(1));
    expect(tags.first.text, '16个老书虫在看');
    expect(tags.first.textColor, '#D7A461FF');
    expect(tags.first.bgColor, '#D7A4611A');
  });
}
