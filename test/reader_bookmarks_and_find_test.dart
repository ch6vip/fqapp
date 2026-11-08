import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/widgets/reader/reader_bookmarks_panel.dart';
import 'package:fqapp/widgets/reader/reader_find_panel.dart';
import 'package:fqapp/widgets/wenku/src/performance_preferences.dart';
import 'package:fqapp/widgets/wenku/wenku_overlay.dart';

const _mark = ReaderBookmark(
  bookId: 'book',
  chapterId: 'chapter',
  title: '第一章',
  text: '保存位置的摘录',
  sourceOffset: 17,
  createdAt: 123,
);

ReaderBookmark _at(int offset, {String bookId = 'book'}) => ReaderBookmark(
  bookId: bookId,
  chapterId: 'chapter',
  title: '第一章',
  text: '摘录 $offset',
  sourceOffset: offset,
  createdAt: offset,
);

Widget _host(Widget child) => MaterialApp(
  builder: (context, child) => PerformanceScope(
    preferences: const PerformancePreferences(enabled: true),
    child: MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: true, highContrast: true),
      child: child!,
    ),
  ),
  home: Scaffold(body: child),
);

void main() {
  group('literal chapter search', () {
    test('empty and over-120 UTF-16-unit queries have no matches', () async {
      const paragraphs = [ReaderFindParagraph(start: 20, text: 'abc')];
      for (final query in ['', '   ', 'x' * 121, '😀' * 61]) {
        final result = await findInReader(paragraphs, query);
        expect(result.matches, isEmpty);
        expect(result.truncated, isFalse);
      }
      final accepted = await findInReader([
        ReaderFindParagraph(start: 0, text: 'x' * 120),
      ], 'x' * 120);
      expect(accepted.matches, hasLength(1));
    });

    test('regex metacharacters are literal and offsets are global', () async {
      final result = await findInReader(const [
        ReaderFindParagraph(start: 19, text: 'aa [a].* aa'),
        ReaderFindParagraph(start: 150, text: '[A].*'),
      ], ' [a].* ');
      expect(result.matches.map((m) => (m.start, m.end, m.paragraph)), [
        (22, 27, 0),
        (150, 155, 1),
      ]);
      expect(() => result.matches.clear(), throwsUnsupportedError);
    });

    test('Unicode case folding preserves UTF-16 offsets and Chinese', () async {
      const paragraphs = [
        ReaderFindParagraph(start: 40, text: '😀 Éé Ωω 中文 中文'),
      ];
      final accents = await findInReader(paragraphs, 'é');
      expect(accents.matches.map((m) => (m.start, m.end)), [
        (43, 44),
        (44, 45),
      ]);
      expect((await findInReader(paragraphs, 'ω')).matches, hasLength(2));
      final chinese = await findInReader(paragraphs, '中文');
      expect(chinese.matches.map((m) => (m.start, m.end)), [
        (49, 51),
        (52, 54),
      ]);
      final emoji = (await findInReader(paragraphs, '😀')).matches.single;
      expect((emoji.start, emoji.end), (40, 42));
    });

    test(
      'exactly 500 is not truncated; 501 caps without extra result',
      () async {
        for (final count in [500, 501]) {
          final result = await findInReader([
            ReaderFindParagraph(start: 31, text: 'a' * count),
          ], 'a');
          expect(result.matches, hasLength(500));
          expect(result.matches.last.end, 531);
          expect(result.truncated, count == 501);
        }
      },
    );

    test(
      'large chapter uses the compute path with global offsets intact',
      () async {
        final result = await findInReader([
          ReaderFindParagraph(start: 10, text: '${'x' * (64 * 1024 + 1)}中文'),
        ], '中文');
        final match = result.matches.single;
        expect((match.start, match.end, match.paragraph), (65547, 65549, 0));
      },
    );

    test('IME helper distinguishes composition from cursor selection', () {
      expect(
        ReaderFindPanel.isComposing(
          const TextEditingValue(
            text: 'zhong',
            composing: TextRange(start: 0, end: 5),
          ),
        ),
        isTrue,
      );
      expect(
        ReaderFindPanel.isComposing(
          const TextEditingValue(
            text: '中文',
            selection: TextSelection(baseOffset: 0, extentOffset: 2),
          ),
        ),
        isFalse,
      );
      expect(
        ReaderFindPanel.isComposing(
          const TextEditingValue(composing: TextRange.collapsed(0)),
        ),
        isFalse,
      );
    });

    testWidgets(
      'debounce and submit wait for IME; clearing removes old matches',
      (tester) async {
        await tester.pumpWidget(
          _host(
            const ReaderFindPanel(
              paragraphs: [ReaderFindParagraph(start: 29, text: '中文内容')],
              preset: ReaderThemePreset.light,
            ),
          ),
        );
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('reader-find-field')),
        );
        final controller = field.controller!;
        controller.value = const TextEditingValue(
          text: '中文',
          composing: TextRange(start: 0, end: 2),
        );
        field.onSubmitted!('中文');
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.byKey(const ValueKey('reader-find-result-0')),
          findsNothing,
        );
        expect(find.text('完成输入后查找'), findsOneWidget);
        controller.value = const TextEditingValue(text: '中文');
        await tester.pump(const Duration(milliseconds: 179));
        expect(
          find.byKey(const ValueKey('reader-find-result-0')),
          findsNothing,
        );
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(find.text('1 处匹配'), findsOneWidget);
        controller.clear();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('reader-find-result-0')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'chapter replacement cancels pending search and returns new global anchor',
      (tester) async {
        final paragraphs = ValueNotifier<List<ReaderFindParagraph>>([
          const ReaderFindParagraph(start: 10, text: 'match'),
        ]);
        addTearDown(paragraphs.dispose);
        await tester.pumpWidget(_host(const SizedBox(key: ValueKey('anchor'))));
        final selected = showJellySheet<ReaderFindMatch>(
          context: tester.element(find.byKey(const ValueKey('anchor'))),
          reduceMotion: true,
          builder: (_) => ValueListenableBuilder<List<ReaderFindParagraph>>(
            valueListenable: paragraphs,
            builder: (_, value, _) => ReaderFindPanel(
              paragraphs: value,
              preset: ReaderThemePreset.light,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('reader-find-field')),
        );
        field.controller!.text = 'match';
        await tester.pump(const Duration(milliseconds: 60));
        paragraphs.value = [
          const ReaderFindParagraph(start: 999, text: 'match'),
        ];
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('reader-find-result-0')));
        await tester.pumpAndSettle();
        final match = (await selected)!;
        expect((match.start, match.end), (999, 1004));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('bookmark serialization', () {
    test('stable tuple identity is delimiter-safe and round trips', () {
      final copy = ReaderBookmark.fromMap(
        jsonDecode(jsonEncode(_mark.toMap())),
      )!;
      expect(copy.toMap(), _mark.toMap());
      expect(jsonDecode(copy.key), ['book', 'chapter', 17]);
      expect(_at(17).key, _mark.key);
      expect(_at(18).key, isNot(_mark.key));
      expect(
        ReaderBookmark.fromMap({..._mark.toMap(), 'text': '', 'title': ''}),
        isNotNull,
      );
    });

    test(
      'rejects malformed fields, non-finite/fractional/negative numbers',
      () {
        expect(ReaderBookmark.fromMap(null), isNull);
        expect(ReaderBookmark.fromMap([]), isNull);
        for (final field in [
          'bookId',
          'chapterId',
          'title',
          'text',
          'sourceOffset',
          'createdAt',
        ]) {
          expect(
            ReaderBookmark.fromMap({..._mark.toMap()}..remove(field)),
            isNull,
          );
          expect(
            ReaderBookmark.fromMap({..._mark.toMap(), field: null}),
            isNull,
          );
        }
        for (final field in ['bookId', 'chapterId']) {
          expect(
            ReaderBookmark.fromMap({..._mark.toMap(), field: '  '}),
            isNull,
          );
        }
        for (final field in ['sourceOffset', 'createdAt']) {
          for (final invalid in [
            -1,
            .5,
            double.nan,
            double.infinity,
            double.negativeInfinity,
            '1',
          ]) {
            expect(
              ReaderBookmark.fromMap({..._mark.toMap(), field: invalid}),
              isNull,
            );
          }
          expect(
            ReaderBookmark.fromMap({..._mark.toMap(), field: 0.0}),
            isNotNull,
          );
        }
      },
    );
  });

  group('local encrypted bookmark storage', () {
    late Directory dir;
    late SecureKeyProvider keys;
    late Box<dynamic> box;
    late ReaderBookmarkStore store;
    late bool wasReady;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fqapp-reader-bookmarks-');
      Hive.init(dir.path);
      keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
      box = await EncryptedHive.openBox<dynamic>(
        Hive,
        'reader_bookmarks_v1',
        keys: keys,
      );
      wasReady = ReaderBookmarkStore.hiveReady;
      ReaderBookmarkStore.hiveReady = true;
      store = ReaderBookmarkStore(hive: Hive);
    });

    tearDown(() async {
      store.changes.dispose();
      ReaderBookmarkStore.hiveReady = wasReady;
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test(
      'serialized add/remove, book isolation, encrypted reopen and notification',
      () async {
        await Future.wait([
          store.add(_at(2)),
          store.add(_at(1)),
          store.add(_at(3, bookId: 'other')),
        ]);
        expect((await store.loadBook('book')).map((m) => m.sourceOffset), [
          2,
          1,
        ]);
        expect(store.changes.value, 3);
        await store.remove(_at(1).key);
        expect(store.changes.value, 4);
        await box.close();
        // Reopen through the same shared encryption setup without a platform key channel.
        box = await EncryptedHive.openBox<dynamic>(
          Hive,
          'reader_bookmarks_v1',
          keys: keys,
        );
        expect((await store.loadBook('book')).single.sourceOffset, 2);
        final reopened = ReaderBookmarkStore(hive: Hive);
        addTearDown(reopened.changes.dispose);
        expect((await reopened.loadBook('other')).single.sourceOffset, 3);
        expect(await Hive.boxExists('reader_bookmarks_v1_enc'), isTrue);
        expect(await Hive.boxExists('reader_bookmarks_v1'), isFalse);
      },
    );

    test(
      'cap refuses new records but permits same-anchor update; never evicts',
      () async {
        final limited = ReaderBookmarkStore(hive: Hive, maxEntries: 1);
        addTearDown(limited.changes.dispose);
        await limited.add(_mark);
        await expectLater(limited.add(_at(18)), throwsStateError);
        expect((await limited.loadBook('book')).single.toMap(), _mark.toMap());
        expect(limited.changes.value, 1);
        await limited.add(_at(17));
        expect((await limited.loadBook('book')).single.text, '摘录 17');
        await limited.remove(_mark.key);
        await limited.add(_at(18));
        expect((await limited.loadBook('book')).single.sourceOffset, 18);
        expect(() => ReaderBookmarkStore(maxEntries: 0), throwsArgumentError);
      },
    );

    test(
      'not-ready and open failures surface; retry is not poisoned',
      () async {
        ReaderBookmarkStore.hiveReady = false;
        await expectLater(store.loadBook('book'), throwsStateError);
        await expectLater(store.add(_mark), throwsStateError);
        await expectLater(store.remove(_mark.key), throwsStateError);
        ReaderBookmarkStore.hiveReady = true;
        final faulty = _FaultyHive(_FaultyBox(box))..failOpen = true;
        final failed = ReaderBookmarkStore(hive: faulty);
        addTearDown(failed.changes.dispose);
        await expectLater(failed.loadBook('book'), throwsStateError);
        expect(failed.changes.value, 0);
        faulty.failOpen = false;
        await failed.add(_mark);
        expect((await failed.loadBook('book')).single.key, _mark.key);
      },
    );

    test(
      'read, save and delete failures surface without false notifications',
      () async {
        final faultyBox = _FaultyBox(box);
        final failed = ReaderBookmarkStore(hive: _FaultyHive(faultyBox));
        addTearDown(failed.changes.dispose);
        faultyBox.failWrite = true;
        await expectLater(failed.add(_mark), throwsStateError);
        expect(failed.changes.value, 0);
        faultyBox.failWrite = false;
        await failed.add(_mark);
        faultyBox.failRead = true;
        await expectLater(failed.loadBook('book'), throwsStateError);
        faultyBox.failRead = false;
        faultyBox.failWrite = true;
        await expectLater(failed.remove(_mark.key), throwsStateError);
        expect(failed.changes.value, 1);
        expect((await failed.loadBook('book')).single.key, _mark.key);
        faultyBox.failWrite = false;
        await failed.remove(_mark.key);
        expect(await failed.loadBook('book'), isEmpty);
      },
    );

    test(
      'corrupt persisted records fail visibly and are not discarded',
      () async {
        await store.add(_mark);
        await box.put('broken', {'sourceOffset': -1});
        await expectLater(store.loadBook('book'), throwsFormatException);
        expect(box.length, 2);
        await box.delete('broken');
        expect((await store.loadBook('book')).single.key, _mark.key);
      },
    );
  });

  group('bookmark panel', () {
    testWidgets(
      'read errors preserve list; save errors retry and changes reload',
      (tester) async {
        final store = _PanelStore([_mark]);
        addTearDown(store.changes.dispose);
        var attempts = 0;
        await tester.pumpWidget(
          _host(
            ReaderBookmarksPanel(
              bookId: 'book',
              preset: ReaderThemePreset.light,
              store: store,
              onAdd: () async {
                if (++attempts == 1) throw StateError('save failed');
                final mark = _at(18);
                await store.add(mark);
                return mark;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('本书 1 条记录'), findsOneWidget);
        store.failRead = true;
        store.changes.value++;
        await tester.pumpAndSettle();
        expect(find.text('书签读取失败，请重试'), findsOneWidget);
        expect(find.text(_mark.text), findsOneWidget);
        store.failRead = false;
        await tester.tap(
          find.byKey(const ValueKey('reader-bookmarks-retry-read')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reader-add-bookmark')));
        await tester.pumpAndSettle();
        expect(find.text('书签保存失败，请重试'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('reader-bookmarks-retry-action')),
        );
        await tester.pumpAndSettle();
        expect(attempts, 2);
        expect(find.text('本书 2 条记录'), findsOneWidget);
        expect(
          store.saves,
          1,
          reason: 'onAdd saves; panel must not double-save',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('initial failure is not an empty book and retry recovers', (
      tester,
    ) async {
      final store = _PanelStore([])..failRead = true;
      addTearDown(store.changes.dispose);
      await tester.pumpWidget(
        _host(
          ReaderBookmarksPanel(
            bookId: 'book',
            preset: ReaderThemePreset.light,
            store: store,
            onAdd: () async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本书 0 条记录'), findsNothing);
      expect(find.text('书签读取失败，请重试'), findsOneWidget);
      store.failRead = false;
      await tester.tap(
        find.byKey(const ValueKey('reader-bookmarks-retry-read')),
      );
      await tester.pumpAndSettle();
      expect(find.text('本书 0 条记录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'delete always confirms; failure preserves bookmark and retry confirms again',
      (tester) async {
        final store = _PanelStore([_mark]);
        addTearDown(store.changes.dispose);
        await tester.pumpWidget(
          _host(
            ReaderBookmarksPanel(
              bookId: 'book',
              preset: ReaderThemePreset.light,
              store: store,
              onAdd: () async => null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final delete = find.byKey(
          ValueKey('reader-bookmark-delete-${_mark.key}'),
        );
        await tester.tap(delete);
        await tester.pumpAndSettle();
        expect(store.deletes, 0);
        expect(find.byKey(const ValueKey('archive-confirm')), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('reader-bookmark-cancel-delete')),
        );
        await tester.pumpAndSettle();
        expect(store.records, hasLength(1));
        store.failDelete = true;
        await tester.tap(delete);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('reader-bookmark-confirm-delete')),
        );
        await tester.pumpAndSettle();
        expect(find.text('书签删除失败，请重试'), findsOneWidget);
        expect(store.records, hasLength(1));
        store.failDelete = false;
        await tester.tap(
          find.byKey(const ValueKey('reader-bookmarks-retry-action')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('archive-confirm')), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('reader-bookmark-confirm-delete')),
        );
        await tester.pumpAndSettle();
        expect(store.deletes, 2);
        expect(find.text('本书 0 条记录'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}

/// Fault injection around a real encrypted Hive box, without a platform channel.
class _FaultyHive implements HiveInterface {
  _FaultyHive(this.wrapped);
  final _FaultyBox wrapped;
  bool failOpen = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (failOpen) throw StateError('open failed');
    if (invocation.memberName == #isBoxOpen) return true;
    if (invocation.memberName == #box) return wrapped;
    return super.noSuchMethod(invocation);
  }
}

class _FaultyBox implements Box<dynamic> {
  _FaultyBox(this.delegate);
  final Box<dynamic> delegate;
  bool failRead = false;
  bool failWrite = false;

  @override
  bool get isOpen => delegate.isOpen;
  @override
  int get length => delegate.length;
  @override
  Iterable<dynamic> get values {
    if (failRead) throw StateError('read failed');
    return delegate.values;
  }

  @override
  bool containsKey(dynamic key) => delegate.containsKey(key);
  @override
  Future<void> put(dynamic key, dynamic value) {
    if (failWrite) throw StateError('write failed');
    return delegate.put(key, value);
  }

  @override
  Future<void> delete(dynamic key) {
    if (failWrite) throw StateError('delete failed');
    return delegate.delete(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PanelStore extends ReaderBookmarkStore {
  _PanelStore(List<ReaderBookmark> records) : records = List.of(records);
  final List<ReaderBookmark> records;
  bool failRead = false;
  bool failDelete = false;
  int saves = 0;
  int deletes = 0;

  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async {
    if (failRead) throw StateError('read failed');
    return records.where((m) => m.bookId == bookId).toList();
  }

  @override
  Future<void> add(ReaderBookmark record) async {
    saves++;
    records.add(record);
    changes.value++;
  }

  @override
  Future<void> remove(String key) async {
    deletes++;
    if (failDelete) throw StateError('delete failed');
    records.removeWhere((m) => m.key == key);
    changes.value++;
  }
}
