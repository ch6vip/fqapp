import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_cell_blocks.dart';
import 'package:fqapp/widgets/home/home_design.dart';

/// `b8w.xml` and `av1.xml` measure a rank row and a feed card differently from
/// the shapes fqapp shipped before: the rank row carries the `secondary_info_
/// list` tags under its title (the TagLayout `o$g$a.b2` revives), the card has
/// no author line and only one title line, and the card's score sits on the
/// title row. These tests pin the parts a layout regression would silently
/// undo.
void main() {
  MediaItem book({
    String id = 'b1',
    String title = '书一',
    String author = '',
    String intro = '',
    double? score,
    List<String> rankTags = const [],
    List<MediaRecTag> recTags = const [],
  }) => MediaItem(
    id: id,
    title: title,
    cover: '',
    author: author,
    badge: '',
    ep: '',
    kind: 'book',
    intro: intro,
    score: score,
    rankTags: rankTags,
    recTags: recTags,
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  group('HomeRankRow', () {
    testWidgets('keeps a title to one line and shows no author', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 360,
          child: HomeRankRow(
            item: book(title: '一个非常非常长的书名用来验证它只占一行', author: '某作者'),
            index: 0,
            onTap: () {},
          ),
        ),
      );

      final title = tester.widget<Text>(find.text('一个非常非常长的书名用来验证它只占一行'));
      // `b8w.xml` 的 `ftb` 是 `android:lines="1"`。
      expect(title.maxLines, 1);
      // 作者不在行副标题的数据源里（那是 secondary_info_list），无处显示。
      expect(find.text('某作者'), findsNothing);
    });

    testWidgets('renders the secondary info tags under the title', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 360,
          child: HomeRankRow(
            item: book(rankTags: const ['多人二刷', '9320万热度']),
            index: 0,
            onTap: () {},
          ),
        ),
      );

      // `o$g$a.b2` → `bindRankTags`：一行 TagLayout，条目间是分隔点。
      final subtitle = tester.widget<Text>(find.text('多人二刷 · 9320万热度'));
      // `e44`/TagLayout 文字：12sp（@dimen/qy），#66000000（gray_40）。
      expect(subtitle.style!.fontSize, 12);
      expect(subtitle.style!.color, const Color(0x66000000));
      expect(subtitle.maxLines, 1);
    });

    testWidgets('keeps a single title line when the payload has no tags', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 360,
          child: HomeRankRow(item: book(), index: 0, onTap: () {}),
        ),
      );

      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('paints the top three indices gold and the rest black', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 360,
          child: Column(
            children: [
              for (var i = 0; i < 4; i++)
                HomeRankRow(
                  item: book(id: 'b$i'),
                  index: i,
                  onTap: () {},
                ),
            ],
          ),
        ),
      );

      Color colorOf(String label) =>
          tester.widget<Text>(find.text(label)).style!.color!;

      // `SkinDelegate.setTextColor(view, 2131561676)` = #FFDCAD6D for i + 1 <= 3.
      expect(colorOf('1'), const Color(0xFFDCAD6D));
      expect(colorOf('3'), const Color(0xFFDCAD6D));
      // 其余是 `@color/abd` = skin_color_black_light (#FF000000)；本客户端用
      // 自己的墨色 palette.ink 代替纯黑，与全站正文一致。
      expect(colorOf('4'), const HomePalette(false).ink);
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

  group('HomeBookCard', () {
    testWidgets('writes the score as a white badge on the cover', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 360,
          child: HomeBookCard(item: book(score: 9.3), onTap: () {}),
        ),
      );

      final score = tester.widget<Text>(find.text('9.3分'));
      // 服务端模板 single_book_v0.0.2：评分是封面左下角的白色 12sp Medium
      // 角标（带阴影），不是橙色横排。
      expect(score.style!.fontSize, 12);
      expect(score.style!.color, Colors.white);
      // 角标左下 10/8：比封面底部高 8dp 以上。
      expect(
        tester.getBottomLeft(find.text('9.3分')).dy,
        lessThan(tester.getBottomLeft(find.byType(HomeBookCard)).dy - 7),
      );
    });

    testWidgets('renders the recommend-reason chips under the abstract', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 360,
          child: HomeBookCard(
            item: book(
              intro: '简介',
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

      final chip = tester.widget<Text>(find.text('16个老书虫在看'));
      // 服务端配色：番茄金文字。
      expect(chip.style!.color, const Color(0xFFD7A461));
      // chip 在简介之下（y 更大）。
      expect(
        tester.getTopLeft(find.text('16个老书虫在看')).dy,
        greaterThan(tester.getTopLeft(find.text('简介')).dy),
      );
    });

    testWidgets('drops the score when the payload has none', (tester) async {
      await pump(
        tester,
        SizedBox(
          width: 360,
          child: HomeBookCard(item: book(), onTap: () {}),
        ),
      );

      // `j6` 在分数为空时写「暂无评分」，而 `av1.xml` 的 `ajr` 位官方默认在
      // 无分数时也是隐藏的，所以这里判空即可。
      expect(find.text('暂无评分'), findsNothing);
      expect(find.textContaining('分'), findsNothing);
    });

    testWidgets(
      'shows one title line, no author line and a two-line abstract',
      (tester) async {
        await pump(
          tester,
          SizedBox(
            width: 360,
            child: HomeBookCard(
              item: book(
                title: '一个小说的书名',
                author: '某作者',
                intro: '书摘内容，用来验证摘要占两行。',
              ),
              onTap: () {},
            ),
          ),
        );

        // Vertical card (S0): the title gets two lines, not one.
        expect(tester.widget<Text>(find.text('一个小说的书名')).maxLines, 2);
        // 模板：14sp Medium。
        expect(find.text('某作者'), findsNothing);
        expect(tester.widget<Text>(find.text('书摘内容，用来验证摘要占两行。')).maxLines, 2);
      },
    );
  });
}
