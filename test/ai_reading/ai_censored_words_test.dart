import 'package:flutter_test/flutter_test.dart';
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
      expect(recovery.text, contains('无法确定原词时保留原文'));
      expect(recovery.text, contains('wcnm'));
      expect(recovery.text, contains('我踏马'));
      expect(recovery.text, contains('不要因包含粗口而擅自净化'));
      expect(recovery.hash, isNot(plain.hash));
      expect(recovery.promptId, isNot(plain.promptId));
      expect(recovery.source, plain.source);
    }
  });

  test('disabled option preserves built-in prompt exactly', () {
    final plain = aiResolvePrompt(bookPrompt: null, globalPrompt: null);
    expect(plain.text, kAiDefaultBehaviorPrompt);
    expect(plain.text, isNot(contains(kAiRestoreCensoredWordsPrompt)));
  });
}
