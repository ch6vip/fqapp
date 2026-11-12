// Real runner/channel/SSIP/D-Bus acceptance target. Never uses a daily profile.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:fqapp/services/linux_platform.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/system_tts.dart';
import 'package:fqapp/services/app_log.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!predicate()) {
    check(DateTime.now().isBefore(deadline), 'runtime timeout');
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.instance.install();
  await LinuxPlatform.install();
  runApp(
    const MaterialApp(home: Scaffold(body: Text('Isolated desktop test'))),
  );
  await WidgetsBinding.instance.endOfFrame;
  final root = Platform.environment['FQAPP_DESKTOP_TEST_ROOT']!;
  void signal(String name) => File('$root/$name').writeAsStringSync('');
  bool signalled(String name) => File('$root/$name').existsSync();
  try {
    final received = <Map>[];
    final sub = SystemTts.events.listen((e) {
      if (e is Map) received.add(e);
    });
    final engines = await SystemTts.engines();
    check(
      engines.engines.any((e) => e.package == 'espeak-ng'),
      'missing real module',
    );
    await SystemTts.initialize(
      const SystemTtsPreferences(engine: 'espeak-ng', rate: 1.2, volume: .4),
    );
    await SystemTts.setVolume(.6);
    await SystemTts.speak('这是第一句。', 'one');
    await SystemTts.speak('这是第二句。', 'two', queue: true);
    await until(
      () => received.any((e) => e['type'] == 'done' && e['id'] == 'two'),
    );
    final done = received
        .where((e) => e['type'] == 'done')
        .map((e) => e['id'])
        .toList();
    check(done.join(',') == 'one,two', 'queue completion order: $received');
    check(
      received.any((e) => e['type'] == 'start' && e['id'] == 'one'),
      'no begin',
    );
    await SystemTts.speak(List.filled(200, '取消长句。').join(), 'cancelled');
    await until(
      () => received.any((e) => e['type'] == 'start' && e['id'] == 'cancelled'),
    );
    await SystemTts.pause();
    await SystemTts.speak('取消之后仍可朗读。', 'after');
    await until(
      () => received.any((e) => e['type'] == 'done' && e['id'] == 'after'),
    );
    check(
      !received.any((e) => e['type'] == 'done' && e['id'] == 'cancelled'),
      'late cancelled done',
    );
    stdout.writeln(
      'PASS SSIP engines/Chinese/rate/volume/queue/start/done/cancel',
    );
    signal('disconnect');
    await until(() => received.any((e) => e['type'] == 'engine_stopped'));
    bool rejected = false;
    try {
      await SystemTts.initialize(const SystemTtsPreferences());
    } on PlatformException {
      rejected = true;
    }
    check(rejected, 'missing daemon falsely succeeded');
    signal('reconnect');
    await until(() => signalled('restarted'));
    await SystemTts.initialize(const SystemTtsPreferences(engine: 'espeak-ng'));
    await SystemTts.speak('重新连接成功。', 'reconnected');
    await until(
      () =>
          received.any((e) => e['type'] == 'done' && e['id'] == 'reconnected'),
    );
    stdout.writeln('PASS disconnect error/reconnect real callback');
    for (final method in ['pause', 'stop', 'initialize']) {
      await SystemTts.speak(
        List.filled(200, '拒绝取消测试。').join(),
        'reject-$method',
      );
      await until(
        () => received.any(
          (e) => e['type'] == 'start' && e['id'] == 'reject-$method',
        ),
      );
      signal('reject-cancel');
      bool failed = false;
      try {
        await const MethodChannel(
          'fqapp/system_tts',
        ).invokeMethod<dynamic>(method);
      } on PlatformException catch (e) {
        failed = e.code == 'TTS_ERROR';
      }
      check(failed, '$method accepted rejected CANCEL');
      File('$root/reject-cancel').deleteSync();
      await SystemTts.stop(); // disconnected stop is idempotent
      await SystemTts.initialize(
        const SystemTtsPreferences(engine: 'espeak-ng', volume: .4),
      );
    }
    stdout.writeln('PASS rejected CANCEL pause/stop/initialize and reconnect');
    const native = MethodChannel('fqapp/native_player');
    final owner = NativePlayer.allocateRemoteOwner();
    final actions = <String>[];
    final seeks = <int>[];
    NativePlayer.setRemoteCommandHandler(
      owner: owner,
      onAction: actions.add,
      onSeek: seeks.add,
      onSetting: (property, value) async {
        await const MethodChannel('fqapp/system_tts').invokeMethod<void>(
          property == 'Volume' ? 'setVolume' : 'setRate',
          {property == 'Volume' ? 'volume' : 'rate': value},
        );
        final actual = await const MethodChannel(
          'fqapp/system_tts',
        ).invokeMapMethod<String, dynamic>('getPlaybackSettings');
        return (actual![property == 'Volume' ? 'volume' : 'rate'] as num)
            .toDouble();
      },
    );
    final metadata = {
      'owner': owner,
      'title': 'Synthetic book',
      'episode': 'Chapter',
      'playing': true,
      'positionMs': 1000,
      'durationMs': 30000,
      'speed': 1.0,
      'volume': .4,
      'minimumRate': .25,
      'maximumRate': 4.0,
      'hasNext': true,
      'transportV2': true,
      'seekSupported': true,
    };
    // Driver holds the bus name before launch; this instance must not steal it.
    rejected = false;
    try {
      await native.invokeMethod<void>('startListenForeground', metadata);
    } on PlatformException catch (e) {
      rejected = e.code == 'MPRIS_OWNER_BUSY';
    }
    check(rejected, 'stole other process MPRIS name');
    signal('release-name');
    await until(() => signalled('name-released'));
    await native.invokeMethod<void>('startListenForeground', metadata);
    await NativePlayer.startListenForeground(
      owner: owner,
      title: 'Synthetic book',
      episode: 'Chapter',
      positionMs: 1000,
      durationMs: 30000,
      linuxTts: true,
      minimumRate: .25,
      maximumRate: 4,
    );
    signal('mpris');
    await until(() => signalled('controls-done'));
    check(
      actions.join(',') == 'pause,play,playPause,next,next,pause',
      'transport actions: $actions',
    );
    check(
      seeks.length == 4 &&
          seeks[0] >= 2000 &&
          seeks[1] == 5000 &&
          seeks[2] == 0,
      'seek payload: $seeks',
    );
    final seekRange = File(
      '$root/rate-seek-range',
    ).readAsStringSync().split(' ').map(int.parse).toList();
    check(
      seeks[3] >= seekRange[0] && seeks[3] <= seekRange[1],
      'rate change moved the relative seek base: ${seeks[3]} / $seekRange',
    );
    metadata['hasNext'] = false;
    await native.invokeMethod<void>('startListenForeground', metadata);
    signal('no-next');
    await until(() => signalled('no-next-done'));
    metadata['seekSupported'] = false;
    await native.invokeMethod<void>('startListenForeground', metadata);
    signal('no-seek');
    await until(() => signalled('no-seek-done'));
    check(
      actions.join(',') == 'pause,play,playPause,next,next,pause' &&
          seeks.length == 4,
      'capability gates dispatched an action',
    );
    await native.invokeMethod<void>('stopListenForeground', {'owner': 'stale'});
    signal('stale-stop');
    await until(() => signalled('stale-checked'));
    await native.invokeMethod<void>('stopListenForeground', {'owner': owner});
    signal('released');
    await until(() => signalled('released-checked'));
    stdout.writeln(
      'PASS real D-Bus owner/metadata/status/position/transport/seek/release',
    );
    final caps = await const MethodChannel(
      'fqapp/desktop_session',
    ).invokeMapMethod<String, dynamic>('capabilities');
    check(
      caps?['lockEvents'] == false,
      'subscription falsely promises reliable lock',
    );
    // A private bus without a desktop inhibitor must report failure, not success.
    rejected = false;
    try {
      await const MethodChannel(
        'fqapp/desktop_session',
      ).invokeMethod<void>('setKeepScreenOn', {'on': true});
    } on PlatformException catch (e) {
      rejected = e.code == 'INHIBIT_UNAVAILABLE';
    }
    check(rejected, 'inhibit falsely acknowledged');
    await const MethodChannel(
      'fqapp/desktop_session',
    ).invokeMethod<void>('setKeepScreenOn', {'on': false});
    await SystemTts.speak(List.filled(100, '关窗测试。').join(), 'close');
    await until(
      () => received.any((e) => e['type'] == 'start' && e['id'] == 'close'),
    );
    await sub.cancel();
    stdout.writeln('READY_CLOSE active speech');
    await windowManager.close();
  } catch (error, stack) {
    stderr.writeln('FAIL $error\n$stack');
    exit(1);
  }
}
