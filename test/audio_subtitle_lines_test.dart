import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/widgets/audio/audio_subtitle_lines.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SubtitleTrack layout(
    SubtitleTrack track, {
    double width = 100,
    Duration duration = Duration.zero,
    TextScaler scaler = TextScaler.noScaling,
  }) => layoutInlineSubtitleLines(
    track: track,
    width: width,
    duration: duration,
    style: const TextStyle(fontSize: 10, fontFamily: 'Ahem'),
    textScaler: scaler,
    textDirection: TextDirection.ltr,
  );

  test('splits Chinese at row capacity with proportional media times', () {
    final source = SubtitleTrack([
      SubtitleCue(startMs: 1000, text: '\u4e00' * 20),
      const SubtitleCue(startMs: 5000, text: 'next'),
    ]);
    final lines = layout(source);
    expect(lines.cues.map((cue) => cue.startMs), [1000, 3000, 5000]);
    expect(lines.cues.take(2).map((cue) => cue.text), [
      '\u4e00' * 10,
      '\u4e00' * 10,
    ]);
    expect(lines.indexAt(const Duration(milliseconds: 2999)), 0);
    expect(lines.indexAt(const Duration(milliseconds: 3000)), 1);
    expect(source.cues, hasLength(2));
    expect(source.cues.first.text, '\u4e00' * 20);
  });

  test('uses chapter duration to time the final cue lines', () {
    final source = SubtitleTrack([SubtitleCue(startMs: 1000, text: 'x' * 20)]);
    expect(
      layout(
        source,
        duration: const Duration(seconds: 11),
      ).cues.map((cue) => cue.startMs),
      [1000, 6000],
    );
    expect(layout(source).cues.map((cue) => cue.startMs), [1000, 4000]);
  });

  test('keeps Latin words intact and preserves all text', () {
    const text = 'one two three four';
    final lines = layout(
      const SubtitleTrack([SubtitleCue(startMs: 0, text: text)]),
    );
    expect(lines.cues.map((cue) => cue.text), ['one two ', 'three four']);
    expect(lines.cues.map((cue) => cue.text).join(), text);
  });

  test('narrow wrapping preserves emoji and combining graphemes', () {
    const text = 'A\u{1f469}\u200d\u{1f4bb}e\u0301B';
    final lines = layout(
      const SubtitleTrack([SubtitleCue(startMs: 0, text: text)]),
      width: 1,
    );
    expect(lines.cues.map((cue) => cue.text), text.characters);
    expect(lines.cues.map((cue) => cue.text).join(), text);
  });

  test('explicit newlines keep their source-time offsets', () {
    final lines = layout(
      const SubtitleTrack([SubtitleCue(startMs: 0, text: 'abc\ndef')]),
      duration: const Duration(seconds: 7),
    );
    expect(lines.cues.map((cue) => cue.text), ['abc', 'def']);
    expect(lines.cues.map((cue) => cue.startMs), [0, 4000]);
  });

  test('empty and zero-width inputs do not invent text', () {
    expect(layout(SubtitleTrack.empty).isEmpty, isTrue);
    const track = SubtitleTrack([SubtitleCue(startMs: 0, text: 'hello')]);
    expect(layout(track, width: 0).isEmpty, isTrue);
    expect(
      layout(const SubtitleTrack([SubtitleCue(startMs: 0, text: '')])).isEmpty,
      isTrue,
    );
  });

  test('duplicate source starts remain monotonic', () {
    final lines = layout(
      SubtitleTrack([
        SubtitleCue(startMs: 1000, text: 'x' * 20),
        const SubtitleCue(startMs: 1000, text: 'next'),
      ]),
    );
    expect(lines.cues.map((cue) => cue.startMs), [1000, 1000, 1000]);
  });

  test('cleans boundary punctuation without shifting source-time offsets', () {
    final source = SubtitleTrack([
      SubtitleCue(
        startMs: 0,
        text: '${'\u7532' * 10}\uFF0C${'\u4e59' * 9}\u3002',
      ),
    ]);
    final lines = layout(source, duration: const Duration(milliseconds: 2100));
    expect(lines.cues.map((cue) => cue.text), ['\u7532' * 10, '\u4e59' * 9]);
    expect(lines.cues.map((cue) => cue.startMs), [0, 1000]);
    expect(source.cues.single.text.length, 21);
  });
}
