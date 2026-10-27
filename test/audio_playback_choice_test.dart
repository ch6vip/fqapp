import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/audio_playback_choice.dart';

/// 跳过片头/片尾与睡眠定时三态的纯逻辑。
///
/// 官方依据：`du`/`dq` = 「跳过片头 / 跳过片尾」（按书保存），
/// `cip` = 「听完本章」——与分钟档是两种不同的定时。
void main() {
  group('AudioSkipPoints.introSeek', () {
    test('is a no-op when unset', () {
      expect(AudioSkipPoints.none.introSeek(const Duration(minutes: 10)), isNull);
    });

    test('returns the configured offset', () {
      const points = AudioSkipPoints(introSeconds: 15);
      expect(
        points.introSeek(const Duration(minutes: 10)),
        const Duration(seconds: 15),
      );
    });

    test('is ignored when the chapter is shorter than the offset', () {
      // 片头跳点 >= 总时长会把整章跳掉，属于无效配置。
      const points = AudioSkipPoints(introSeconds: 15);
      expect(points.introSeek(const Duration(seconds: 10)), isNull);
      expect(points.introSeek(Duration.zero), isNull);
    });
  });

  group('AudioSkipPoints.atOutro', () {
    const points = AudioSkipPoints(outroSeconds: 20);

    test('fires only inside the tail window', () {
      const duration = Duration(minutes: 10);
      expect(points.atOutro(const Duration(minutes: 9, seconds: 30), duration),
          isFalse);
      expect(points.atOutro(const Duration(minutes: 9, seconds: 45), duration),
          isTrue);
      expect(points.atOutro(duration, duration), isTrue);
    });

    test('never fires at position zero or with an unknown duration', () {
      const duration = Duration(minutes: 10);
      expect(points.atOutro(Duration.zero, duration), isFalse);
      expect(points.atOutro(const Duration(seconds: 5), Duration.zero), isFalse);
    });

    test('is disabled when the offset is zero', () {
      expect(
        AudioSkipPoints.none.atOutro(
          const Duration(minutes: 10),
          const Duration(minutes: 10),
        ),
        isFalse,
      );
    });
  });

  group('SleepTimerChoice', () {
    test('exposes three mutually exclusive states', () {
      const off = SleepTimerChoice.off();
      const chapter = SleepTimerChoice.endOfChapter();
      const minutes = SleepTimerChoice.minutes(30);

      expect(off.isOff, isTrue);
      expect(chapter.isOff, isFalse);
      expect(minutes.isOff, isFalse);
      expect(chapter.endOfChapter, isTrue);
      expect(minutes.endOfChapter, isFalse);
      expect(minutes.minutes, 30);
    });

    test('compares by value so the sheet can mark the active row', () {
      expect(const SleepTimerChoice.minutes(15),
          const SleepTimerChoice.minutes(15));
      expect(const SleepTimerChoice.minutes(15),
          isNot(const SleepTimerChoice.minutes(30)));
      expect(const SleepTimerChoice.off(), isNot(const SleepTimerChoice.endOfChapter()));
    });
  });
}
