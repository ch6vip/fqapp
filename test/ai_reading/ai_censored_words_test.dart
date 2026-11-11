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

  test('recovery is a request segment, not part of the editable prompt', () {
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
      // The editable prompt and its identity stay free of program-owned
      // segments, so candidates and history cannot absorb or duplicate them.
      expect(recovery.text, plain.text);
      expect(recovery.hash, plain.hash);
      expect(recovery.promptId, plain.promptId);
      expect(recovery.source, plain.source);
      expect(recovery.restoreCensoredWords, isTrue);
      expect(plain.restoreCensoredWords, isFalse);

      final system = aiBuildSystemPrompt(
        behaviorPrompt: recovery.text,
        outputMode: AiOutputMode.jsonObject,
        restoreCensoredWords: recovery.restoreCensoredWords,
      );
      expect(system, contains(kAiRestoreCensoredWordsPrompt.trim()));
      expect(system, contains('允许根据上下文推测'));
      expect(system, contains('wcnm'));
      expect(system, contains('我踏马'));
      expect(system, contains('不要因包含粗口而擅自净化'));
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
    final system = aiBuildSystemPrompt(
      behaviorPrompt: plain.text,
      outputMode: AiOutputMode.jsonObject,
    );
    expect(system, isNot(contains(kAiRestoreCensoredWordsPrompt.trim())));
  });
}
