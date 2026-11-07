import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/detail/detail_archive.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('the inline catalogue marks the saved chapter', (tester) async {
    await _pumpBook(
      tester,
      store: MemoryReaderStore(
        entry: {'kind': 'book', 'chapterId': 'chapter-23', 'episode': 0},
      ),
    );
    // The ported page lists the whole catalogue; the saved chapter (index 22)
    // carries the upstream `上次阅读` marker and no other row does.
    final saved = await _scrollToDirectoryEntry(tester, 22);
    expect(tester.widget<DetailArchiveChapterRow>(saved).current, isTrue);
    expect(
      find.descendant(
        of: saved,
        matching: find.text('上次阅读', skipOffstage: false),
      ),
      findsOneWidget,
    );
    final neighbours = tester
        .widgetList<DetailArchiveChapterRow>(
          find.byType(DetailArchiveChapterRow, skipOffstage: false),
        )
        .where((row) => row.index != 22);
    expect(neighbours.every((row) => !row.current), isTrue);
  });

  testWidgets('without progress the catalogue starts at chapter one', (
    tester,
  ) async {
    await _pumpBook(tester);
    // The inline catalogue is a lazy sliver below the intro; scroll until its
    // first row exists, then inspect the built neighbourhood.
    await _scrollToDirectoryEntry(tester, 0);
    final rows = tester
        .widgetList<DetailArchiveChapterRow>(
          find.byType(DetailArchiveChapterRow, skipOffstage: false),
        )
        .toList();
    expect(rows.take(3).map((row) => row.title), [
      '第1章 故事的另一种可能',
      '第2章 故事的另一种可能',
      '第3章 故事的另一种可能',
    ]);
    expect(rows.every((row) => !row.current), isTrue);
    expect(find.text('上次阅读', skipOffstage: false), findsNothing);
  });

  testWidgets('the rating appears exactly once on the page', (tester) async {
    await _pumpBook(
      tester,
      detailPayload: {
        'data': {
          'abstract': _description,
          'score': '8.7',
          'read_count': '124000',
        },
      },
    );
    expect(find.text('8.7'), findsOneWidget);
    expect(find.textContaining('12.4万人在读'), findsOneWidget);
    // 旧版在书评区又放了一张评分卡。
    expect(find.byKey(const Key('detail_score_card')), findsNothing);
    expect(find.byKey(const Key('detail_stats_row')), findsNothing);
  });

  testWidgets('the bottom bar stays mounted and disabled while loading', (
    tester,
  ) async {
    final pending = Completer<List<List<Chapter>>>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(const []);
    });
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          readerStore: MemoryReaderStore(),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) => pending.future,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // The ported bottom dock stays mounted; its primary pill is disabled
    // while the catalogue is still loading.
    final primary = find.byKey(const Key('detail_read_button'));
    expect(primary, findsOneWidget);
    expect(tester.widget<GlassPillButton>(primary).onPressed, isNull);
    expect(find.byKey(const Key('detail_shelf_button')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final kind in ['book', 'audio', 'manga']) {
    testWidgets('$kind uses the plain 简介 heading', (tester) async {
      await _pumpBook(
        tester,
        item: MediaItem(
          id: 'detail-$kind',
          title: '标题',
          cover: '',
          author: '作者',
          badge: '',
          ep: '',
          kind: kind,
        ),
      );
      expect(find.text('简介', skipOffstage: false), findsOneWidget);
      expect(find.text('书籍简介', skipOffstage: false), findsNothing);
    });
  }

  testWidgets('only the saved catalogue row says 上次阅读', (tester) async {
    await _pumpBook(
      tester,
      store: MemoryReaderStore(
        entry: {'kind': 'book', 'chapterId': 'chapter-23', 'episode': 0},
      ),
    );
    await _scrollToDirectoryEntry(tester, 22);
    // Upstream marks the saved chapter with `上次阅读`; the old per-row
    // 已读/读到这里 labels are gone.
    expect(find.text('上次阅读', skipOffstage: false), findsOneWidget);
    expect(find.text('已读', skipOffstage: false), findsNothing);
    expect(find.text('读到这里', skipOffstage: false), findsNothing);
  });

  testWidgets('目录 carries the progress line, percentage and bar', (
    tester,
  ) async {
    await _pumpBook(
      tester,
      store: MemoryReaderStore(
        entry: {
          'kind': 'book',
          'chapterId': 'chapter-23',
          'episode': 0,
          'time': DateTime.now()
              .subtract(const Duration(days: 3))
              .millisecondsSinceEpoch,
        },
      ),
    );
    // 上次读到横条已删，进度并入目录：23/146 取整 16%。
    expect(find.byKey(const Key('detail_resume_row')), findsNothing);
    expect(find.byKey(const Key('detail_progress_line')), findsOneWidget);
    expect(find.text('已读 16% · 3 天前'), findsOneWidget);
    expect(find.text('23 / 146'), findsOneWidget);
    final fill = tester.getSize(find.byKey(const Key('detail_progress_fill')));
    final bar = tester.getSize(find.byKey(const Key('detail_progress_bar')));
    expect(fill.width, closeTo(bar.width * 0.16, 0.5));
    expect(find.byKey(const Key('detail_resume_label')), findsNothing);
  });

  testWidgets('without progress the 目录 line and bar are hidden', (
    tester,
  ) async {
    await _pumpBook(tester);
    expect(find.byKey(const Key('detail_progress_line')), findsNothing);
    expect(find.byKey(const Key('detail_progress_bar')), findsNothing);
    expect(find.textContaining('已读 '), findsNothing);
  });

  testWidgets('the hero shows rank, update line and tags when present', (
    tester,
  ) async {
    await _pumpBook(
      tester,
      detailPayload: {
        'data': {
          'abstract': _description,
          'creation_status': '1',
          'last_chapter_title': '第820章 北境来信',
          'book_rank_info': [
            {'text': '科幻热榜 第3名'},
          ],
          'tags': '废土,群像,冒险',
        },
      },
    );
    expect(find.byKey(const Key('detail_rank_pill')), findsOneWidget);
    expect(find.text('科幻热榜 第3名'), findsOneWidget);
    expect(find.byKey(const Key('detail_update_line')), findsOneWidget);
    expect(find.text('更新至 第820章 北境来信'), findsOneWidget);
    final heroTags = find.byKey(const Key('detail_hero_tags'));
    expect(heroTags, findsOneWidget);
    for (final tag in ['废土', '群像', '冒险']) {
      expect(
        find.descendant(of: heroTags, matching: find.text(tag)),
        findsOneWidget,
      );
    }
    // 标签不再留在简介下面。
    expect(find.byKey(const Key('detail_tag_chips')), findsNothing);
  });

  testWidgets('the hero omits rank and update when there is no data', (
    tester,
  ) async {
    await _pumpBook(tester);
    expect(find.byKey(const Key('detail_rank_pill')), findsNothing);
    expect(find.byKey(const Key('detail_update_line')), findsNothing);
    expect(find.byKey(const Key('detail_hero_tags')), findsNothing);
  });

  testWidgets('a finished book hides the update line', (tester) async {
    await _pumpBook(
      tester,
      detailPayload: {
        'data': {
          'abstract': _description,
          'creation_status': '0',
          'last_chapter_title': '第820章 北境来信',
        },
      },
    );
    expect(find.byKey(const Key('detail_update_line')), findsNothing);
  });

  testWidgets('rank_title is the fallback when book_rank_info is empty', (
    tester,
  ) async {
    await _pumpBook(
      tester,
      detailPayload: {
        'data': {'abstract': _description, 'rank_title': '飙升榜 第9名'},
      },
    );
    expect(find.text('飙升榜 第9名'), findsOneWidget);
  });

  testWidgets('the update line falls back to the last directory chapter', (
    tester,
  ) async {
    await _pumpBook(
      tester,
      detailPayload: {
        'data': {'abstract': _description, 'creation_status': '1'},
      },
    );
    expect(find.text('更新至 第146章 故事的另一种可能'), findsOneWidget);
  });

  testWidgets('no detail text declares the monospace family', (tester) async {
    await _pumpBook(
      tester,
      store: MemoryReaderStore(
        entry: {'kind': 'book', 'chapterId': 'chapter-23', 'episode': 0},
      ),
      detailPayload: {
        'data': {
          'abstract': _description,
          'score': '8.7',
          'read_count': '124000',
          'creation_status': '1',
          'last_chapter_title': '第820章 北境来信',
          'book_rank_info': [
            {'text': '科幻热榜 第3名'},
          ],
          'tags': '废土,群像',
        },
      },
    );
    // Archive codes are Latin/number labels and deliberately use the shared
    // monospace `ArchiveCode`; body copy must still avoid the family.
    final paragraphs = tester.renderObjectList<RenderParagraph>(
      find.byType(RichText, skipOffstage: false),
    );
    expect(paragraphs, isNotEmpty);
    final codeParagraphs = find
        .descendant(
          of: find.byType(ArchiveCode, skipOffstage: false),
          matching: find.byType(RichText, skipOffstage: false),
        )
        .evaluate()
        .map((element) => element.renderObject)
        .toSet();
    for (final paragraph in paragraphs) {
      if (codeParagraphs.contains(paragraph)) continue;
      final styles = <TextStyle?>[paragraph.text.style];
      paragraph.text.visitChildren((span) {
        if (span is TextSpan) styles.add(span.style);
        return true;
      });
      for (final style in styles) {
        expect(style?.fontFamily, isNot('monospace'));
        expect(
          style?.fontFamilyFallback ?? const <String>[],
          isNot(contains('monospace')),
        );
      }
    }
    // The ID row lives in the intro sliver above the catalogue, so it is
    // built without scrolling even for a long directory.
    final idRow = find.byKey(const Key('detail_id_row'), skipOffstage: false);
    expect(idRow, findsOneWidget);
    final id = tester.widget<SelectableText>(
      find.byKey(const Key('detail_id_text'), skipOffstage: false),
    );
    expect(id.style?.fontFamily, isNot('monospace'));
    expect(
      id.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  testWidgets('下载 folds whole-book download and offline cache into a sheet', (
    tester,
  ) async {
    await _pumpBook(tester);
    // 改版后页面上没有额外的缓存入口，下载弹层承载这两个行为。
    expect(find.byKey(const Key('detail_read_cached')), findsNothing);
    await tester.tap(find.byKey(const Key('detail_action_下载')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail_download_sheet')), findsOneWidget);
    expect(find.byKey(const Key('detail_download_all')), findsOneWidget);
    expect(find.byKey(const Key('detail_download_cached')), findsOneWidget);
    expect(find.text('整本下载'), findsOneWidget);
    expect(find.text('离线缓存'), findsOneWidget);
  });

  testWidgets('e-ink renders the rating and primary action in black', (
    tester,
  ) async {
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    await _pumpBook(
      tester,
      detailPayload: {
        'data': {
          'abstract': _description,
          'score': '8.7',
          'read_count': '124000',
        },
      },
    );
    final star = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('detail_rating_line')),
        matching: find.text('★'),
      ),
    );
    expect(star.style!.color, Colors.black);
    // Upstream glass on e-ink is an opaque white plate with black ink, not the
    // old solid black pill.
    final plate = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const Key('detail_read_button')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(plate.color, Colors.white);
    expect((plate.shape! as RoundedRectangleBorder).side.color, Colors.black);
  });
}

Future<Finder> _scrollToDirectoryEntry(WidgetTester tester, int index) async {
  final target = find.byKey(
    ValueKey('detail-directory-entry-$index'),
    skipOffstage: false,
  );
  // The whole catalogue is a lazy sliver below the intro; drag until the
  // target row has been built.
  for (var i = 0; i < 80 && target.evaluate().isEmpty; i++) {
    await tester.drag(
      find.byKey(const Key('detail_scroll')),
      const Offset(0, -300),
    );
    await tester.pump();
  }
  expect(target, findsWidgets);
  return target;
}

Future<void> _pumpBook(
  WidgetTester tester, {
  MemoryReaderStore? store,
  Map<String, dynamic>? detailPayload,
  MediaItem? item,
}) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: DetailPage(
        item: item ?? _book,
        readerStore: store ?? MemoryReaderStore(),
        detailLoader: (id, {String tab = '小说'}) async =>
            detailPayload ??
            {
              'data': {'abstract': _description},
            },
        directoryLoader: (id, {String tab = '小说'}) async => [
          List.generate(
            146,
            (index) => Chapter(
              itemId: 'chapter-${index + 1}',
              title: '第${index + 1}章 故事的另一种可能',
              volumeName: index < 73 ? '第一卷 · 初见' : '终卷 · 星河',
            ),
          ),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _book = MediaItem(
  id: 'detail-design-book',
  title: '开局废弃宗门，我召唤了大帝长老',
  cover: '',
  author: '香瓜贼甜',
  badge: '玄幻脑洞',
  ep: '',
  kind: 'book',
);

const _description =
    '苏狂身穿玄幻世界，激活无敌宗门系统，开局就召唤出了大帝境强者！\n'
    '只要招收天才进宗，还能继续抽取各类强者！\n'
    '而且弟子的修为精进，也能百倍返还给苏狂！\n'
    '于是，一段关于宗门、成长与奇遇的故事，就这样开始。';
