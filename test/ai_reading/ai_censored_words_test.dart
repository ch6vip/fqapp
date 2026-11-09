import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/ai_reading/ai_chapter_snapshot.dart';
import 'package:fqapp/services/ai_reading/ai_protocol.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/ai_reading/ai_prompt.dart';

void main() {
  test(
    'older settings default off and enabled setting survives persistence',
    () {
      expect(AiGlobalSettings.fromJson({}).restoreCensoredWords, isFalse);
      final settings = const AiGlobalSettings().copyWith(
        restoreCensoredWords: true,
      );
      expect(
        AiGlobalSettings.fromJson(settings.toJson()).restoreCensoredWords,
        isTrue,
      );
      expect(settings.copyWith(enabled: true).restoreCensoredWords, isTrue);
      expect(
        settings.copyWith(restoreCensoredWords: false).restoreCensoredWords,
        isFalse,
      );
    },
  );

  test('recovery augments the selected prompt and changes its identity', () {
    for (final bookPrompt in <String?>[null, '单书校对规则']) {
      final plain = aiResolvePrompt(
        bookPrompt: bookPrompt,
        globalPrompt: '全局规则',
      );
      final recovery = aiResolvePrompt(
        bookPrompt: bookPrompt,
        globalPrompt: '全局规则',
        restoreCensoredWords: true,
      );
      expect(recovery.text, startsWith(plain.text));
      expect(recovery.text, contains(kAiRestoreCensoredWordsPrompt));
      expect(recovery.text, contains('允许根据上下文推测'));
      expect(recovery.text, contains('wcnm'));
      expect(recovery.text, contains('我踏马'));
      expect(recovery.text, contains('不要因包含粗口而擅自净化'));
      expect(recovery.hash, isNot(plain.hash));
      expect(recovery.promptId, isNot(plain.promptId));
      expect(recovery.source, plain.source);
    }
  });

  test('repeated stars can be located and replaced using adjacent context', () {
    final snapshot = AiChapterSnapshotBuilder.fromContent(
      ChapterContent(
        blocks: [const ChapterParagraph('他打开*****发消息。她看着*****发呆。')],
      ),
      '',
    );
    final result = const AiValidator().validateContent(
      '{"edits":[{"original":"打开*****发消息","replacement":"打开微信发消息","category":"屏蔽词还原","reason":"根据上下文推测还原"}]}',
      snapshot,
    );
    expect(result.valid, isTrue);
    expect(result.spans.single.replacement, '打开微信发消息');
    final ambiguous = const AiValidator().validateContent(
      '{"edits":[{"original":"*****","replacement":"微信","category":"屏蔽词还原","reason":"根据上下文推测还原"}]}',
      snapshot,
    );
    expect(ambiguous.valid, isFalse);
  });

  test('disabled option preserves built-in prompt exactly', () {
    final plain = aiResolvePrompt(bookPrompt: null, globalPrompt: null);
    expect(plain.text, kAiDefaultBehaviorPrompt);
    expect(plain.text, isNot(contains(kAiRestoreCensoredWordsPrompt)));
  });
}
