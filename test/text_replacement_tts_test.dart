import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/system_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'TTS transforms raw initial and next local chapter exactly once',
    () async {
      final book = SystemTtsBook(
        bookId: 'local:tts',
        title: 'Book',
        chapters: [
          Chapter(itemId: '1', title: 'C1', volumeName: ''),
          Chapter(itemId: '2', title: 'C2', volumeName: ''),
        ],
        startIndex: 0,
        localOnly: true,
        initialContent: ChapterContent.fromPlainText('A'),
        textLoader: (_) async => 'A',
        replacementSnapshot: TextReplacementSnapshot(
          enabled: true,
          revision: 1,
          rules: [
            const TextReplacementRule(id: '1', pattern: 'A', replacement: 'AA'),
          ],
        ),
      );
      for (final index in [0, 1]) {
        final result = await book.loadDisplay(index);
        expect(
          result
              .bodyBlocks(book.chapters[index].title)
              .whereType<ChapterParagraph>()
              .map((p) => p.text)
              .join('\n'),
          'AA',
        );
      }
      expect((book.initialContent.blocks.single as ChapterParagraph).text, 'A');
    },
  );
  test(
    'TTS does not strip body that becomes identical to chapter title',
    () async {
      final book = SystemTtsBook(
        bookId: 'local:title',
        title: 'Book',
        chapters: [Chapter(itemId: '1', title: 'Title', volumeName: '')],
        startIndex: 0,
        initialContent: ChapterContent.fromPlainText('body'),
        replacementSnapshot: TextReplacementSnapshot(
          enabled: true,
          rules: [
            const TextReplacementRule(
              id: '1',
              pattern: 'body',
              replacement: 'Title',
            ),
          ],
        ),
      );
      final result = await book.loadDisplay(0);
      expect(
        result.bodyBlocks('Title').whereType<ChapterParagraph>().single.text,
        'Title',
      );
    },
  );
}
