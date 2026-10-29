import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/services/audio_time_point_lookup.dart';

AudioSyncPoint _point({
  required int startTime,
  required int startPara,
  bool isTitle = false,
}) => AudioSyncPoint(
  startTime: startTime,
  startPara: startPara,
  startParaOff: 0,
  endPara: startPara,
  endParaOff: 10,
  isTitle: isTitle,
);

AudioTimeTrack _track(List<AudioSyncPoint> points) => AudioTimeTrack(points);

void main() {
  test('上游段号命中时直接用它的起播毫秒', () {
    final track = _track([
      _point(startTime: 0, startPara: 0),
      _point(startTime: 6800, startPara: 1),
      _point(startTime: 15400, startPara: 2),
    ]);
    expect(startMsForParagraph(track, paraIndex: 1, ordinal: 1), 6800);
  });

  test('同一段有多个句子时取最早的那个点', () {
    final track = _track([
      _point(startTime: 6800, startPara: 1),
      _point(startTime: 9000, startPara: 1),
    ]);
    expect(startMsForParagraph(track, paraIndex: 1, ordinal: 0), 6800);
  });

  test('纯文本章节没有段号，按段序对', () {
    final track = _track([
      _point(startTime: 0, startPara: 0),
      _point(startTime: 6800, startPara: 1),
      _point(startTime: 15400, startPara: 2),
    ]);
    expect(startMsForParagraph(track, paraIndex: null, ordinal: 2), 15400);
  });

  test('标题占第 0 段时按段序 +1 也能对上', () {
    // 时间轴的 0 号段是标题（isBody 为假），正文从 1 号段开始；阅读页已经
    // 剥掉了标题，所以第 0 个正文段对应 1 号段。
    final track = _track([
      _point(startTime: 0, startPara: 99999, isTitle: true),
      _point(startTime: 1200, startPara: 1),
      _point(startTime: 7800, startPara: 2),
    ]);
    expect(startMsForParagraph(track, paraIndex: null, ordinal: 0), 1200);
  });

  test('空时间轴与对不上的段号都返回 null（调用方落回章首）', () {
    expect(startMsForParagraph(AudioTimeTrack.empty, ordinal: 3), isNull);
    final track = _track([_point(startTime: 0, startPara: 0)]);
    expect(startMsForParagraph(track, paraIndex: 7, ordinal: 9), isNull);
    expect(startMsForParagraph(track, ordinal: -1), isNull);
  });
}
