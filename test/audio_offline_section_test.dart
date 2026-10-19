import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/audio_download_store.dart';
import 'package:fqapp/services/audio_downloader.dart';
import 'package:fqapp/widgets/audio/audio_offline_section.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'support/fakes.dart';

class _StubStore implements AudioDownloadStore {
  _StubStore(this.dir);

  final Directory dir;
  final Map<String, CachedAudioChapter> chapters = {};
  final List<String> removedBooks = [];

  @override
  bool isReady = true;

  @override
  final ValueNotifier<int> changes = ValueNotifier(0);

  @override
  Future<void> warmUp() async {}

  @override
  Future<Directory> directory() async => dir;

  @override
  Future<void> ensureBook(CachedAudioBook book) async {}

  @override
  Future<void> saveChapter(CachedAudioChapter chapter) async {
    chapters['${chapter.itemId}|${chapter.toneId}'] = chapter;
    changes.value++;
  }

  @override
  Future<bool> isDownloaded(String itemId, {required String toneId}) async =>
      chapters.containsKey('$itemId|$toneId');

  @override
  Future<CachedAudioChapter?> chapter(
    String itemId, {
    required String toneId,
  }) async => chapters['$itemId|$toneId'];

  @override
  Future<Set<String>> downloadedIds(
    String bookId, {
    required String toneId,
  }) async => {
    for (final entry in chapters.values)
      if (entry.bookId == bookId && entry.toneId == toneId) entry.itemId,
  };

  @override
  Future<void> removeChapter(String itemId, {required String toneId}) async {
    chapters.remove('$itemId|$toneId');
    changes.value++;
  }

  @override
  Future<void> removeBook(String bookId, {required String toneId}) async {
    removedBooks.add('$bookId|$toneId');
    chapters.removeWhere(
      (_, value) => value.bookId == bookId && value.toneId == toneId,
    );
    changes.value++;
  }

  @override
  Future<int> totalBytes() async =>
      chapters.values.fold<int>(0, (sum, chapter) => sum + chapter.bytes);
}

void main() {
  late Directory temp;
  late _StubStore store;
  late AudioDownloader downloader;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fqapp-audio-section-');
    store = _StubStore(temp);
    downloader = AudioDownloader(
      store: store,
      resolve: (bookId, itemId, toneId) async =>
          throw StateError('本用例不触发真实下载'),
    );
  });

  tearDown(() async {
    temp.deleteSync(recursive: true);
    await Future<void>.delayed(Duration.zero);
  });

  CachedAudioChapter cached(String itemId, {int bytes = 1024}) =>
      CachedAudioChapter(
        bookId: 'book',
        itemId: itemId,
        toneId: 'toneA',
        title: '第$itemId章',
        index: 0,
        keyHex: '00112233445566778899aabbccddeeff',
        bytes: bytes,
        filePath: '${temp.path}${Platform.pathSeparator}$itemId.m4a',
        cachedAt: 1,
      );

  Widget harness({Widget? child}) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child:
            child ??
            AudioOfflineSection(
              bookId: 'book',
              title: '测试书',
              cover: '',
              toneId: 'toneA',
              chapters: [
                Chapter(itemId: '1', title: '第1章', volumeName: ''),
                Chapter(itemId: '2', title: '第2章', volumeName: ''),
              ],
              downloader: downloader,
              store: store,
            ),
      ),
    ),
  );

  testWidgets('shows the empty state and offers the whole-book download', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.text('离线音频'), findsOneWidget);
    expect(find.text('尚未下载音频'), findsOneWidget);
    expect(find.text('下载剩余 2 章音频'), findsOneWidget);
    // 没有已下载内容时不提供删除。
    expect(find.byKey(const Key('audio_offline_remove')), findsNothing);
  });

  testWidgets('reports how many chapters and how much space are on disk', (
    tester,
  ) async {
    store.chapters['1|toneA'] = cached('1', bytes: 3 * 1024 * 1024);
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    expect(find.text('已下载 1 / 2 章 · 3.0 MB'), findsOneWidget);
    expect(find.text('下载剩余 1 章音频'), findsOneWidget);
    expect(find.byKey(const Key('audio_offline_remove')), findsOneWidget);
  });

  testWidgets('deleting asks for confirmation and calls the store', (
    tester,
  ) async {
    store.chapters['1|toneA'] = cached('1');
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('audio_offline_remove')));
    await tester.pumpAndSettle();
    expect(find.text('删除离线音频'), findsWidgets);

    await tester.tap(find.byKey(const Key('audio_offline_remove_confirm')));
    await tester.pump();
    await tester.pump();

    expect(store.removedBooks, ['book|toneA']);
    expect(find.text('尚未下载音频'), findsOneWidget);
  });

  testWidgets('the chapter cache sheet renders the audio section it is given', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        child: ChapterCacheSheet(
          book: CachedBook(
            id: 'book',
            title: '测试书',
            cover: '',
            chapters: [Chapter(itemId: '1', title: '第1章', volumeName: '')],
          ),
          currentIndex: 0,
          cache: MemoryChapterCache(),
          loader: (chapter) async => '',
          extraSection: const Text('离线音频占位'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('离线音频占位'), findsOneWidget);
  });
}
