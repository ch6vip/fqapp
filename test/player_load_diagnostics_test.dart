import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/player_load_diagnostics.dart';

void main() {
  test('records disjoint phases, frame delay and background time once', () {
    var now = Duration.zero;
    final samples = <PlayerLoadSample>[];
    final diagnostics = PlayerLoadDiagnostics(
      now: () => now,
      report: samples.add,
    );
    final trace = diagnostics.begin(
      attempt: 1,
      episode: 3,
      trigger: 'switch',
      appActive: true,
    );
    trace.source = 'prefetchPending';
    now = const Duration(milliseconds: 120);
    trace.stage('create');
    now = const Duration(milliseconds: 200);
    trace.stage('autoplayWait');
    trace.setAppActive(false);
    now = const Duration(milliseconds: 700);
    trace.setAppActive(true);
    trace.playRequested();
    now = const Duration(milliseconds: 800);
    trace.firstFrame();
    trace.finish('firstFrame');
    trace.finish('disposed');
    trace.stage('ignored');
    expect(samples, hasLength(1));
    final sample = samples.single;
    expect(sample.stagesMs, {
      'address': 120,
      'create': 80,
      'autoplayWait': 500,
      'firstFrame': 100,
    });
    expect(sample.totalMs, 800);
    expect(sample.backgroundMs, 500);
    expect(sample.firstFrameMs, 800);
    expect(sample.playToFirstFrameMs, 100);
    expect(sample.source, 'prefetchPending');
  });

  test(
    'an early native frame never produces a negative play-to-frame time',
    () {
      var now = Duration.zero;
      final samples = <PlayerLoadSample>[];
      final trace = PlayerLoadDiagnostics(
        now: () => now,
        report: samples.add,
      ).begin(attempt: 1, episode: 1, trigger: 'initial', appActive: true);
      now = const Duration(milliseconds: 30);
      trace.firstFrame();
      now = const Duration(milliseconds: 90);
      trace.playRequested();
      trace.finish('firstFrame');
      expect(samples.single.firstFrameMs, 30);
      expect(samples.single.totalMs, 90);
      expect(samples.single.playToFirstFrameMs, isNull);
    },
  );

  test(
    'aborted attempts retain the active phase without fabricating a frame',
    () {
      var now = Duration.zero;
      final samples = <PlayerLoadSample>[];
      final trace = PlayerLoadDiagnostics(
        now: () => now,
        report: samples.add,
      ).begin(attempt: 2, episode: 4, trigger: 'retry', appActive: false);
      now = const Duration(milliseconds: 400);
      trace.finish('superseded');
      final sample = samples.single;
      expect(sample.outcome, 'superseded');
      expect(sample.stagesMs, {'address': 400});
      expect(sample.backgroundMs, 400);
      expect(sample.firstFrameMs, isNull);
      expect(sample.playToFirstFrameMs, isNull);
      expect(() => sample.stagesMs['address'] = 0, throwsUnsupportedError);
    },
  );

  test('reporter failure cannot interrupt playback', () {
    final trace = PlayerLoadDiagnostics(
      report: (_) => throw StateError('logger'),
    ).begin(attempt: 1, episode: 1, trigger: 'initial', appActive: true);
    expect(() => trace.finish('firstFrame'), returnsNormally);
  });

  test(
    'failed attempt records phase and numeric codes without raw secrets',
    () {
      var now = Duration.zero;
      final samples = <PlayerLoadSample>[];
      final trace = PlayerLoadDiagnostics(
        now: () => now,
        report: samples.add,
      ).begin(attempt: 7, episode: 2, trigger: 'initial', appActive: true);
      now = const Duration(milliseconds: 125);
      trace.stage('create');
      now = const Duration(milliseconds: 350);
      trace.fail(errorCode: 2004, httpStatusCode: 403);

      final sample = samples.single;
      expect(sample.outcome, 'error');
      expect(sample.failureStage, 'create');
      expect(sample.stagesMs, {'address': 125, 'create': 225});
      expect(sample.errorCode, 2004);
      expect(sample.httpStatusCode, 403);
      final json = jsonEncode(sample.toJson());
      expect(json, contains('"httpStatusCode":403'));
      expect(json, isNot(contains('url')));
      expect(json, isNot(contains('token')));
    },
  );

  test('unexpected labels cannot inject URL, key or credential text', () {
    var now = Duration.zero;
    final samples = <PlayerLoadSample>[];
    final trace = PlayerLoadDiagnostics(now: () => now, report: samples.add)
        .begin(
          attempt: 1,
          episode: 1,
          trigger: 'https://cdn.invalid/video?token=private',
          appActive: true,
        );
    trace.source = 'https://cdn.invalid/video?token=private';
    trace.stage('key=secret');
    now = const Duration(milliseconds: 20);
    trace.fail(errorCode: 2004, httpStatusCode: 403);

    final sample = samples.single;
    final json = jsonEncode(sample.toJson());
    expect(sample.trigger, 'other');
    expect(sample.source, 'other');
    expect(sample.failureStage, 'other');
    expect(json, isNot(contains('cdn.invalid')));
    expect(json, isNot(contains('private')));
    expect(json, isNot(contains('secret')));
  });
}
