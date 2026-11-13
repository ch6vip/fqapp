import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_full_search.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/text_replacement_engine.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

Chapter _chapter(String id, [String? title]) =>
    Chapter(itemId: id, title: title ?? '第$id章', volumeName: '');

TextReplacementResult _text(String text) {
  final source = ChapterContent.fromPlainText(text, illustrationsChecked: true);
  return TextReplacementResult(
    source: source,
    content: source,
    snapshotRevision: 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'searches every chapter in order and reports partial failures honestly',
    () async {
      final calls = <String>[];
      final controller = ReaderFullSearchController(
        chapters: [_chapter('a'), _chapter('b'), _chapter('c')],
        loadChapter: (chapter) async {
          calls.add(chapter.itemId);
          if (chapter.itemId == 'b') throw StateError('offline');
          return _text(
            chapter.itemId == 'a' ? 'His cat HIS' : 'this is his book',
          );
        },
      );
      addTearDown(controller.dispose);
      final progress = <int>[];
      controller.addListener(() => progress.add(controller.state.scanned));
      await controller.search('his');
      expect(calls, ['a', 'b', 'c']);
      expect(controller.state.matchCount, 4);
      expect(controller.state.groups.map((g) => g.chapterIndex), [0, 2]);
      expect(controller.state.failedChapters.single.itemId, 'b');
      expect(controller.state.scanned, 3);
      expect(controller.state.running, isFalse);
      expect(progress, [0, 1, 2, 3]);
      expect(controller.state.groups.first.hits.first.matchedText, 'His');
    },
  );

  test(
    'new query waits for pending chapter, discards stale results, stays serial',
    () async {
      final pending = Completer<TextReplacementResult>();
      final calls = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;
      final controller = ReaderFullSearchController(
        chapters: [_chapter('a'), _chapter('b')],
        loadChapter: (chapter) async {
          calls.add(chapter.itemId);
          ++inFlight;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          final value = calls.length == 1
              ? await pending.future
              : _text('new new old');
          --inFlight;
          return value;
        },
      );
      addTearDown(controller.dispose);
      final old = controller.search('old');
      final superseded = controller.search('unused');
      final latest = controller.search('new');
      expect(calls, ['a']);
      expect(controller.state.query, 'new');
      expect(controller.state.matchCount, 0);
      pending.complete(_text('old old old'));
      await Future.wait([old, superseded, latest]);
      expect(maxInFlight, 1);
      expect(calls, ['a', 'a', 'b']);
      expect(controller.state.query, 'new');
      expect(controller.state.matchCount, 4);
      expect(controller.state.scanned, 2);
      expect(
        controller.state.groups
            .expand((g) => g.hits)
            .every((h) => h.matchedText == 'new'),
        isTrue,
      );
    },
  );

  test(
    'cancel never publishes pending result or loads another chapter',
    () async {
      final pending = Completer<TextReplacementResult>();
      final calls = <String>[];
      final controller = ReaderFullSearchController(
        chapters: [_chapter('a'), _chapter('b')],
        loadChapter: (chapter) {
          calls.add(chapter.itemId);
          return pending.future;
        },
      );
      addTearDown(controller.dispose);
      final task = controller.search('needle');
      controller.cancel();
      pending.complete(_text('needle'));
      await task;
      expect(calls, ['a']);
      expect(controller.state.cancelled, isTrue);
      expect(controller.state.running, isFalse);
      expect(controller.state.groups, isEmpty);
      expect(controller.state.scanned, 0);
    },
  );

  test('cancelled request can fail later without leaking an error', () async {
    final pending = Completer<TextReplacementResult>();
    var calls = 0;
    final controller = ReaderFullSearchController(
      chapters: [_chapter('a'), _chapter('b')],
      loadChapter: (_) {
        ++calls;
        return pending.future;
      },
    );
    addTearDown(controller.dispose);
    final task = controller.search('needle');
    controller.cancel();
    pending.completeError(StateError('cancelled backend request'));
    await task;
    expect(calls, 1);
    expect(controller.state.failedChapters, isEmpty);
    expect(controller.state.cancelled, isTrue);
  });

  test(
    'dispose drops pending work without notifying or loading more',
    () async {
      final pending = Completer<TextReplacementResult>();
      var calls = 0;
      var updates = 0;
      final controller = ReaderFullSearchController(
        chapters: [_chapter('a'), _chapter('b')],
        loadChapter: (_) {
          ++calls;
          return pending.future;
        },
      );
      controller.addListener(() => ++updates);
      final task = controller.search('needle');
      controller.dispose();
      pending.complete(_text('needle'));
      await task;
      expect(calls, 1);
      expect(updates, 1);
    },
  );

  test('counts the whole book while bounding retained hit snippets', () async {
    final controller = ReaderFullSearchController(
      chapters: [_chapter('a'), _chapter('b'), _chapter('c')],
      maxHitsPerChapter: 2,
      maxVisibleHits: 3,
      loadChapter: (_) async => _text('needle needle needle needle'),
    );
    addTearDown(controller.dispose);
    await controller.search('needle');
    expect(controller.state.matchCount, 12);
    expect(controller.state.scanned, 3);
    expect(controller.state.groups.map((g) => g.hits.length), [2, 1, 0]);
    expect(controller.state.truncated, isTrue);
  });

  test(
    'only body text is searched, preserving image and removed-title coordinates',
    () async {
      final source = ChapterContent(
        blocks: const [
          ChapterImage(url: 'https://example.com/needle.png'),
          ChapterParagraph('needle title'),
          ChapterParagraph('first needle'),
          ChapterImage(url: 'https://example.com/b.png'),
          ChapterParagraph('last needle'),
        ],
      );
      final controller = ReaderFullSearchController(
        chapters: [_chapter('a', 'needle title')],
        loadChapter: (_) async => TextReplacementResult(
          source: source,
          content: source,
          snapshotRevision: 0,
        ),
      );
      addTearDown(controller.dispose);
      await controller.search('needle');
      expect(controller.state.matchCount, 2);
      final layout = _layout('needle title', source);
      for (final hit in controller.state.groups.single.hits) {
        final block = layout.blockAtOffset(
          layout.displayOffsetForSource(hit.sourceParagraphStart),
        )!;
        final range = hit.displayRange(block.text, block.start)!;
        expect(layout.textInRange(range.start, range.end), 'needle');
        expect(layout.sourceOffsetForDisplay(range.start), hit.sourceStart);
      }
    },
  );

  test(
    'exact replacement hit lands deep inside expansion instead of source start',
    () async {
      const title = '甲章';
      const marker = '短标';
      const target = '唯一命中';
      final expanded = '${List.filled(200, '风吹过书页。').join()}$target，结束。';
      final source = ChapterContent(blocks: const [ChapterParagraph(marker)]);
      final replacement = TextReplacementResult(
        source: source,
        content: ChapterContent(blocks: [ChapterParagraph(expanded)]),
        snapshotRevision: 7,
        paragraphMaps: {
          0: TextOffsetMap.fromSegments(marker.length, expanded.length, [
            (
              start: 0,
              end: marker.length,
              outputStart: 0,
              outputEnd: expanded.length,
            ),
          ]),
        },
      );
      final controller = ReaderFullSearchController(
        chapters: [_chapter('a', title)],
        loadChapter: (_) async => replacement,
      );
      addTearDown(controller.dispose);
      await controller.search(target);
      final hit = controller.state.groups.single.hits.single;
      expect(
        hit.matchesSource(ChapterContent.fromCacheText(source.toCacheText())),
        isTrue,
      );
      expect(
        hit.matchesSource(
          ChapterContent(
            blocks: [const ChapterParagraph('新插入段落'), ...source.blocks],
          ),
        ),
        isFalse,
      );
      final layout = _layout(title, source, replacement: replacement);
      final block = layout.blockAtOffset(
        layout.displayOffsetForSource(hit.sourceParagraphStart),
      )!;
      final exact = hit.displayRange(block.text, block.start)!;
      expect(layout.textInRange(exact.start, exact.end), target);
      expect(exact.start, block.start + expanded.indexOf(target));
      expect(layout.pageForOffset(exact.start), greaterThan(0));
      expect(
        layout.pageForOffset(layout.displayOffsetForSource(hit.sourceStart)),
        0,
      );
      expect(
        hit.displayRange(expanded.replaceFirst('风', '雨'), block.start),
        isNull,
      );
    },
  );

  test(
    'large chapter scan uses isolate and still navigates exact UTF-16 range',
    () async {
      final text = '${List.filled(16000, '风吹书页。').join()}😀literal [x]😀';
      final controller = ReaderFullSearchController(
        chapters: [_chapter('a', '')],
        loadChapter: (_) async => _text(text),
      );
      addTearDown(controller.dispose);
      await controller.search('[x]');
      final hit = controller.state.groups.single.hits.single;
      expect(hit.displayRange(text, 0), (
        start: text.indexOf('[x]'),
        end: text.indexOf('[x]') + 3,
      ));
      expect(hit.excerpt.substring(hit.excerptStart, hit.excerptEnd), '[x]');
    },
  );
}

ReaderChapterLayout _layout(
  String title,
  ChapterContent source, {
  TextReplacementResult? replacement,
}) => ReaderChapterLayout(
  title: title,
  content: source,
  replacement: replacement,
  spec: ReaderLayoutSpec(
    viewport: const Size(390, 600),
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  ),
);
