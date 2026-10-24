import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/text_replacement_engine.dart';

TextReplacementSnapshot snapshot(List<TextReplacementRule> rules) =>
    TextReplacementSnapshot(enabled: true, rules: rules, revision: 1);
Future<TextReplacementResult> convert(
  String text,
  List<TextReplacementRule> rules,
) => TextReplacementEngine.instance.transform(
  source: ChapterContent.fromPlainText(text),
  chapterTitle: '',
  snapshot: snapshot(rules),
);
void main() {
  test(
    'cancelling before worker startup returns original without unhandled errors',
    () async {
      final cancellation = TextReplacementCancellation();
      final pending = TextReplacementEngine().transform(
        source: ChapterContent.fromPlainText('original'),
        chapterTitle: '',
        snapshot: snapshot([
          const TextReplacementRule(
            id: '1',
            pattern: 'original',
            replacement: 'changed',
          ),
        ]),
        cancellation: cancellation,
      );
      cancellation.cancel();
      final result = await pending;
      expect(
        (result.content.blocks.single as ChapterParagraph).text,
        'original',
      );
      expect(result.error, isNull);
    },
  );
  test(
    'capture expansion is bounded before constructing the full result',
    () async {
      final result = await convert('a' * 1000, [
        TextReplacementRule(
          id: 'r',
          pattern: '(a+)',
          replacement: r'$1' * 600,
          isRegex: true,
        ),
      ]);
      expect(result.error, contains('大小限制'));
      expect(
        (result.content.blocks.single as ChapterParagraph).text.length,
        1000,
      );
    },
  );
  test('replaces literal text and keeps original content', () async {
    final result = await convert('他来到了漂亮国。', [
      const TextReplacementRule(id: 'a', pattern: '漂亮国', replacement: '美国'),
    ]);
    expect((result.content.blocks.single as ChapterParagraph).text, '他来到了美国。');
    expect((result.source.blocks.single as ChapterParagraph).text, '他来到了漂亮国。');
    final map = result.paragraphMaps[0]!;
    expect(map.toSource(5, bias: TextBoundaryBias.start), 4);
    expect(map.toSource(6, bias: TextBoundaryBias.end), 7);
    expect(map.toDisplay(8, bias: TextBoundaryBias.start), 7);
  });
  test('composes sequential rule mappings and honors disabled rules', () async {
    final result = await convert('xABCz', [
      const TextReplacementRule(id: '1', pattern: 'ABC', replacement: 'B'),
      const TextReplacementRule(id: '2', pattern: 'B', replacement: 'LONG'),
      const TextReplacementRule(
        id: '3',
        pattern: 'z',
        replacement: '!',
        enabled: false,
      ),
    ]);
    expect((result.content.blocks.single as ChapterParagraph).text, 'xLONGz');
    expect(
      result.paragraphMaps[0]!.toSource(3, bias: TextBoundaryBias.start),
      1,
    );
    expect(result.paragraphMaps[0]!.toSource(3, bias: TextBoundaryBias.end), 4);
    expect(
      result.paragraphMaps[0]!.toSource(5, bias: TextBoundaryBias.start),
      4,
    );
  });
  test('expands captures and treats ordinary dollar signs literally', () async {
    final result = await convert('ab12', [
      const TextReplacementRule(
        id: '1',
        pattern: r'(ab)(\d+)',
        replacement: r'$2-$1-$$-$0',
        isRegex: true,
      ),
    ]);
    expect(
      (result.content.blocks.single as ChapterParagraph).text,
      r'12-ab-$-ab12',
    );
    final literal = await convert('a.b', [
      const TextReplacementRule(id: '1', pattern: 'a.b', replacement: r'$1'),
    ]);
    expect((literal.content.blocks.single as ChapterParagraph).text, r'$1');
  });
  test('validates regex and replacement references in worker', () async {
    for (final rule in [
      const TextReplacementRule(
        id: '1',
        pattern: '[',
        replacement: '',
        isRegex: true,
      ),
      const TextReplacementRule(
        id: '1',
        pattern: '(a)',
        replacement: r'$2',
        isRegex: true,
      ),
      const TextReplacementRule(
        id: '1',
        pattern: '(a)',
        replacement: r'$x',
        isRegex: true,
      ),
    ]) {
      await expectLater(
        TextReplacementEngine.instance.validateRule(rule),
        throwsFormatException,
      );
    }
  });
  test(
    'preserves paragraph identity, images, captions and title exclusion',
    () async {
      final source = parseChapterContent(
        '<p>漂亮国</p><p idx="4"><span start_time="20">漂亮国</span></p><img src="https://example.com/a.png" alt="漂亮国">',
      );
      final result = await TextReplacementEngine.instance.transform(
        source: source,
        chapterTitle: '漂亮国',
        snapshot: snapshot([
          const TextReplacementRule(id: '1', pattern: '漂亮国', replacement: ''),
        ]),
      );
      final paragraphs = result.content.blocks
          .whereType<ChapterParagraph>()
          .toList();
      expect(paragraphs.map((p) => p.text), ['漂亮国', '']);
      expect(paragraphs.last.paraIndex, 4);
      expect(paragraphs.last.startMs, 20);
      expect(identical(result.content.blocks.last, source.blocks.last), isTrue);
    },
  );
  test('zero-width regex progresses and unicode matches whole emoji', () async {
    final result = await convert('😀a', [
      const TextReplacementRule(
        id: '1',
        pattern: r'(?=a)',
        replacement: 'X',
        isRegex: true,
      ),
    ]);
    expect((result.content.blocks.single as ChapterParagraph).text, '😀Xa');
    final emoji = await convert('😀a', [
      const TextReplacementRule(
        id: '1',
        pattern: '.',
        replacement: 'X',
        isRegex: true,
      ),
    ]);
    expect((emoji.content.blocks.single as ChapterParagraph).text, 'XX');
  });
  test('output expansion falls back to original with an error', () async {
    final result = await convert('a' * 100, [
      TextReplacementRule(id: '1', pattern: 'a', replacement: 'b' * 2048),
    ]);
    expect(result.error, isNotNull);
    expect((result.content.blocks.single as ChapterParagraph).text, 'a' * 100);
  });
  test(
    'pathological regex times out and leaves engine usable',
    () async {
      final engine = TextReplacementEngine(
        timeout: const Duration(milliseconds: 100),
      );
      final result = await engine.transform(
        source: ChapterContent.fromPlainText('a' * 100),
        chapterTitle: '',
        snapshot: snapshot([
          const TextReplacementRule(
            id: 'bad',
            pattern: r'^(a+)+b$',
            replacement: '',
            isRegex: true,
          ),
        ]),
      );
      expect(result.error, contains('超时'));
      final next = await engine.transform(
        source: ChapterContent.fromPlainText('a'),
        chapterTitle: '',
        snapshot: snapshot([
          const TextReplacementRule(id: 'ok', pattern: 'a', replacement: 'b'),
        ]),
      );
      expect((next.content.blocks.single as ChapterParagraph).text, 'b');
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
