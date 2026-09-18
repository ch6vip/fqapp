import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/listening_session.dart';

import 'support/fakes.dart';

/// network in widget tests.
const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg==';

Widget _app({
  required String text,
  String title = '测试书籍',
  String chapterTitle = '第一章',
  int chapterCount = 2,
  ChapterTextLoader? loader,
  ChapterIdeasLoader? ideasLoader,
  ParagraphCommentResolver? commentResolver,
}) => MaterialApp(
  home: ReaderPage(
    bookId: 'reader-test',
    title: title,
    chapters: [
      for (var i = 0; i < chapterCount; i++)
        Chapter(
          itemId: 'c${i + 1}',
          title: i == 0 ? chapterTitle : '第 ${i + 1} 章',
          volumeName: '正文',
        ),
    ],
    startIndex: 0,
    readerStore: MemoryReaderStore(),
    chapterCache: MemoryChapterCache(),
    chapterLoader: loader ?? (chapter) async => text,
    ideasLoader: ideasLoader,
    commentResolver: commentResolver,
    imageProviderFactory: (image) => MemoryImage(base64Decode(_pixelPng)),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    ListeningSession.instance.clear();
  });

  tearDown(() {
    ListeningSession.instance.clear();
  });

  testWidgets('chapter-end entry opens the ideas end bucket', (tester) async {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requested = <int>[];
    await tester.pumpWidget(
      _app(
        text: '第一段。\n\n第二段。',
        ideasLoader: (itemId) async => ChapterIdeas.fromPayload(const {
          'code': 0,
          'data': {
            'data': {
              '1': {'count': 5},
              '2': {'count': 100},
              '10000': {'count': 20},
            },
          },
        }),
        commentResolver: (itemId, paragraph, cursor) async {
          requested.add(paragraph.paraIndex);
          return const BookCommentPage();
        },
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('reader-scroll-chapter-comments'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    // The 章末 entry must open the greatest paragraph key (the end bucket),
    // not the bucket with the most comments.
    expect(requested, [10000]);
  });
}
