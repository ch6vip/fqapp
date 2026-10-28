import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/audio_play_error.dart';

/// 播放失败时的用户可见文案。
///
/// 官方依据：`ug` = 「本章该音色已下架」、`uj` = 「本章正在审核中，请先看其他章节」。
/// 识别不到就返回 null，由调用方回落到通用文案——不能把裸错误码甩给用户。
void main() {
  test('maps a delisted tone with the swap hint', () {
    final message = audioPlayErrorMessage(
      const ApiException('NO_THIS_TONE'),
      switchedTone: true,
    );
    expect(message, '本章该音色已下架，已为你换用其它音色');
  });

  test('maps a delisted tone without any fallback tone', () {
    final message = audioPlayErrorMessage(const ApiException('NO_THIS_TONE'));
    expect(message, '本章该音色已下架');
  });

  test('maps a chapter under review', () {
    expect(
      audioPlayErrorMessage(const ApiException('CHAPTER_UNDER_REVIEW')),
      '本章正在审核中，请先看其他章节',
    );
    expect(
      audioPlayErrorMessage(const ApiException('本章正在审核')),
      '本章正在审核中，请先看其他章节',
    );
  });

  test('returns null for unknown failures so the caller keeps its own text', () {
    expect(audioPlayErrorMessage(const ApiException('SOMETHING_ELSE')), isNull);
    expect(audioPlayErrorMessage(StateError('boom')), isNull);
  });

  test('prefers the delisted-tone reason over the review marker', () {
    // 两个标记同时出现时，音色下架是更具体的解释。
    expect(
      audioPlayErrorMessage(
        const ApiException('NO_THIS_TONE 审核'),
        switchedTone: true,
      ),
      '本章该音色已下架，已为你换用其它音色',
    );
  });
}
