import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/reader_book_notes.dart';

const _bookmark = ReaderBookmark(
  bookId: 'book',
  chapterId: 'first',
  title: 'Old saved title',
  text: 'bookmark excerpt',
  sourceOffset: 47,
  createdAt: 1000,
);
const _paragraph = ReaderUnderline(
  bookId: 'book',
  chapterId: 'first',
  paraIndex: 71,
  blockIndex: 3,
  text: 'paragraph excerpt',
  createdAt: 3000,
);
const _range = ReaderRangeUnderline(
  bookId: 'book',
  chapterId: 'first',
  start: 83,
  end: 97,
  text: 'range excerpt',
  createdAt: 2000,
);
final _chapters = [
  Chapter(itemId: 'first', title: '第一章', volumeName: '上卷'),
  Chapter(itemId: 'second', title: '第二章', volumeName: '上卷'),
];

class _Bookmarks extends ReaderBookmarkStore {
  List<ReaderBookmark> records = [_bookmark];
  Future<List<ReaderBookmark>> Function(String)? loader;
  bool failRead = false;
  bool failDelete = false;
  final deleted = <String>[];
  int reads = 0;

  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async {
    reads++;
    if (loader != null) return loader!(bookId);
    if (failRead) throw StateError('read failed');
    return records.where((r) => r.bookId == bookId).toList();
  }

  @override
  Future<void> remove(String key) async {
    if (failDelete) throw StateError('delete failed');
    deleted.add(key);
    records.removeWhere((r) => r.key == key);
    changes.value++;
  }
}

class _Underlines extends ReaderUnderlineStore {
  List<ReaderUnderline> paragraphs = [_paragraph];
  List<ReaderRangeUnderline> ranges = [_range];
  bool failRead = false;
  bool failDelete = false;
  final deleted = <String>[];
  int paragraphReads = 0;
  int rangeReads = 0;

  @override
  Future<List<ReaderUnderline>> loadBook(String bookId) async {
    paragraphReads++;
    if (failRead) throw StateError('underline read failed');
    return paragraphs.where((r) => r.bookId == bookId).toList();
  }

  @override
  Future<List<ReaderRangeUnderline>> loadBookRanges(String bookId) async {
    rangeReads++;
    if (failRead) throw StateError('range read failed');
    return ranges.where((r) => r.bookId == bookId).toList();
  }

  @override
  Future<void> remove(String key) async {
    if (failDelete) throw StateError('underline delete failed');
    deleted.add(key);
    paragraphs.removeWhere((r) => r.key == key);
    ranges.removeWhere((r) => r.key == key);
    changes.value++;
  }
}

Widget _host(
  _Bookmarks bookmarks,
  _Underlines underlines, {
  String bookId = 'book',
  List<Chapter>? chapters,
  ReaderThemePreset preset = ReaderThemePreset.light,
  double scale = 1,
  ValueChanged<ReaderBookmark>? onBookmark,
  ValueChanged<ReaderUnderline>? onUnderline,
  ValueChanged<ReaderRangeUnderline>? onRangeUnderline,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: ReaderBookNotes(
      bookId: bookId,
      chapters: chapters ?? _chapters,
      preset: preset,
      bookmarkStore: bookmarks,
      underlineStore: underlines,
      onBookmark: onBookmark ?? (_) {},
      onUnderline: onUnderline ?? (_) {},
      onRangeUnderline: onRangeUnderline ?? (_) {},
    ),
  ),
);

Finder _open(String type, String key) =>
    find.byKey(ValueKey('reader-book-notes-open-$type:$key'));
Finder _delete(String type, String key) =>
    find.byKey(ValueKey('reader-book-notes-delete-$type:$key'));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late _Bookmarks bookmarks;
  late _Underlines underlines;
  setUp(() {
    bookmarks = _Bookmarks();
    underlines = _Underlines();
  });
  tearDown(() {
    bookmarks.changes.dispose();
    underlines.changes.dispose();
  });

  testWidgets(
    'catalogue order, all record types and original navigation objects',
    (tester) async {
      const second = ReaderBookmark(
        bookId: 'book',
        chapterId: 'second',
        title: 'second',
        text: 'second excerpt',
        sourceOffset: 1,
        createdAt: 99999,
      );
      bookmarks.records.insert(0, second);
      Object? selected;
      await tester.pumpWidget(
        _host(
          bookmarks,
          underlines,
          onBookmark: (r) => selected = r,
          onUnderline: (r) => selected = r,
          onRangeUnderline: (r) => selected = r,
        ),
      );
      await tester.pumpAndSettle();
      expect(bookmarks.reads, 1);
      expect(underlines.paragraphReads, 1);
      expect(underlines.rangeReads, 1);
      expect(
        tester.getTopLeft(find.text('第一章')).dy,
        lessThan(tester.getTopLeft(find.text('第二章')).dy),
      );
      expect(find.text('书签'), findsNWidgets(3)); // Filter and two records.
      expect(find.text('段落划线'), findsOneWidget);
      expect(find.text('选文划线'), findsOneWidget);
      expect(find.textContaining('1970/'), findsWidgets);
      await _tap(tester, _open('bookmark', _bookmark.key));
      expect(selected, same(_bookmark));
      await _tap(tester, _open('underline', _paragraph.key));
      expect(selected, same(_paragraph));
      await _tap(tester, _open('underline', _range.key));
      expect(selected, same(_range));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'filters keep both underline formats and preserve outside-catalogue marks',
    (tester) async {
      const outside = ReaderBookmark(
        bookId: 'book',
        chapterId: 'missing',
        title: 'Misleading saved chapter',
        text: 'outside excerpt',
        sourceOffset: 4,
        createdAt: 0,
      );
      bookmarks.records.add(outside);
      await tester.pumpWidget(_host(bookmarks, underlines));
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byKey(const ValueKey('reader-book-notes-filter-underlines')),
      );
      expect(find.text('bookmark excerpt'), findsNothing);
      expect(find.text('paragraph excerpt'), findsOneWidget);
      expect(find.text('range excerpt'), findsOneWidget);
      await _tap(
        tester,
        find.byKey(const ValueKey('reader-book-notes-filter-bookmarks')),
      );
      expect(find.text('paragraph excerpt'), findsNothing);
      expect(find.text('range excerpt'), findsNothing);
      expect(find.text('outside excerpt'), findsOneWidget);
      expect(find.text('目录外章节'), findsOneWidget);
      expect(find.text('Misleading saved chapter'), findsNothing);
      expect(find.text('时间未记录'), findsOneWidget);
    },
  );

  testWidgets(
    'delete requires confirmation, cancellation and failed-delete retry preserve records',
    (tester) async {
      await tester.pumpWidget(_host(bookmarks, underlines));
      await tester.pumpAndSettle();
      await _tap(tester, _delete('bookmark', _bookmark.key));
      expect(bookmarks.deleted, isEmpty);
      await _tap(
        tester,
        find.byKey(const ValueKey('reader-book-notes-cancel-delete')),
      );
      expect(bookmarks.deleted, isEmpty);
      await _tap(tester, _delete('bookmark', _bookmark.key));
      bookmarks.failDelete = true;
      await _tap(
        tester,
        find.byKey(const ValueKey('reader-book-notes-confirm-delete')),
      );
      expect(find.text('书签删除失败，记录仍保留'), findsOneWidget);
      expect(find.text('bookmark excerpt'), findsOneWidget);
      bookmarks.failDelete = false;
      await _tap(
        tester,
        find.byKey(const ValueKey('reader-book-notes-retry-delete')),
      );
      expect(bookmarks.deleted, [_bookmark.key]);
      expect(find.text('bookmark excerpt'), findsNothing);
      expect(underlines.deleted, isEmpty);
      for (final record in [_paragraph, _range]) {
        final key = record is ReaderUnderline
            ? record.key
            : (record as ReaderRangeUnderline).key;
        await _tap(tester, _delete('underline', key));
        await _tap(
          tester,
          find.byKey(const ValueKey('reader-book-notes-confirm-delete')),
        );
      }
      expect(underlines.deleted, [_paragraph.key, _range.key]);
      expect(find.text('本书还没有书签或划线'), findsOneWidget);
    },
  );

  testWidgets(
    'notifications reload both stores and failed reads never appear empty',
    (tester) async {
      bookmarks.failRead = true;
      await tester.pumpWidget(_host(bookmarks, underlines));
      await tester.pumpAndSettle();
      expect(find.text('阅读记录读取失败，请重试'), findsOneWidget);
      expect(find.text('本书还没有书签或划线'), findsNothing);
      bookmarks.failRead = false;
      await _tap(
        tester,
        find.byKey(const ValueKey('reader-book-notes-reload')),
      );
      expect(find.text('bookmark excerpt'), findsOneWidget);
      underlines.failRead = true;
      underlines.changes.value++;
      await tester.pumpAndSettle();
      expect(find.text('阅读记录读取失败，请重试'), findsOneWidget);
      expect(find.text('bookmark excerpt'), findsOneWidget);
      expect(find.text('paragraph excerpt'), findsOneWidget);
      underlines.failRead = false;
      bookmarks.records.clear();
      underlines.paragraphs.clear();
      underlines.ranges.clear();
      bookmarks.changes.value++;
      await tester.pumpAndSettle();
      expect(find.text('本书还没有书签或划线'), findsOneWidget);
      expect(find.text('阅读记录读取失败，请重试'), findsNothing);
    },
  );

  testWidgets(
    'old book reads cannot replace a new book and disposal ignores late completion',
    (tester) async {
      final oldRead = Completer<List<ReaderBookmark>>();
      bookmarks.loader = (bookId) =>
          bookId == 'book' ? oldRead.future : Future.value(const []);
      await tester.pumpWidget(_host(bookmarks, underlines));
      await tester.pump();
      await tester.pumpWidget(_host(bookmarks, underlines, bookId: 'new-book'));
      await tester.pumpAndSettle();
      oldRead.complete([_bookmark]);
      await tester.pumpAndSettle();
      expect(find.text('bookmark excerpt'), findsNothing);
      expect(find.text('本书还没有书签或划线'), findsOneWidget);
      final lateRead = Completer<List<ReaderBookmark>>();
      bookmarks.loader = (_) => lateRead.future;
      bookmarks.changes.value++;
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      lateRead.completeError(StateError('late error'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('replacement detaches old store notifications', (tester) async {
    await tester.pumpWidget(_host(bookmarks, underlines));
    await tester.pumpAndSettle();
    final replacement = _Bookmarks()..records = [];
    addTearDown(replacement.changes.dispose);
    await tester.pumpWidget(_host(replacement, underlines));
    await tester.pumpAndSettle();
    final reads = replacement.reads;
    bookmarks.changes.value++;
    await tester.pumpAndSettle();
    expect(replacement.reads, reads);
    expect(find.text('bookmark excerpt'), findsNothing);
  });

  testWidgets(
    'narrow dark panel supports 2x text and scrolls inline confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(280, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host(bookmarks, underlines, preset: ReaderThemePreset.dark, scale: 2),
      );
      await tester.pumpAndSettle();
      await _tap(tester, _delete('underline', _paragraph.key));
      await _tap(
        tester,
        find.byKey(const ValueKey('reader-book-notes-cancel-delete')),
      );
      await _tap(tester, _open('underline', _range.key));
      expect(tester.takeException(), isNull);
      expect(find.byType(ReaderBookNotes), findsOneWidget);
      expect(
        find.byType(Scaffold),
        findsOneWidget,
      ); // Only the host owns a shell.
    },
  );
}
