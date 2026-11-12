import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/desktop_media.dart';
import 'package:flutter/foundation.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/linux_platform.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/desktop_chapter_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    PlatformChannels.invoke = null;
    PlatformChannels.events = null;
  });

  setUp(() {
    for (final channel in [
      'fqapp/desktop_session',
      'fqapp/desktop_session_events',
      'fqapp/system_tts',
      'fqapp/native_player',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });
  tearDown(() {
    for (final channel in [
      'fqapp/desktop_session',
      'fqapp/desktop_session_events',
      'fqapp/system_tts',
      'fqapp/native_player',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  test('failed reader intent must not retain an awake vote', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final requests = <bool>[];
    var fail = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/desktop_session'),
          (call) async {
            requests.add((call.arguments as Map)['on'] as bool);
            if (fail) throw PlatformException(code: 'INHIBIT_UNAVAILABLE');
            return null;
          },
        );
    final d = DesktopPlatform.instance;
    await expectLater(
      d.invoke('fqapp/reader', 'keepScreenOn', {'on': true}),
      throwsA(isA<PlatformException>()),
    );
    fail = false;
    await d.invoke('fqapp/native_player', 'setKeepScreenOn', {'on': false});
    expect(requests, [
      true,
      false,
    ], reason: 'a rejected reader vote must roll back');
  });
  test('unknown native player operation is unsupported', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await expectLater(
      DesktopPlatform.instance.invoke(
        'fqapp/native_player',
        'unknownAndroidControl',
        null,
      ),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'unsupported_platform',
        ),
      ),
    );
  });
  test(
    'Linux serializes failed reader and newer player awake intents',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final gate = Completer<void>();
      final requests = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('fqapp/desktop_session'),
            (call) async {
              requests.add((call.arguments as Map)['on'] as bool);
              if (requests.length == 1) {
                await gate.future;
                throw PlatformException(code: 'INHIBIT_UNAVAILABLE');
              }
              return null;
            },
          );
      final d = DesktopPlatform.instance;
      final reader = d.invoke('fqapp/reader', 'keepScreenOn', {'on': true});
      final failure = expectLater(reader, throwsA(isA<PlatformException>()));
      final player = d.invoke('fqapp/native_player', 'setKeepScreenOn', {
        'on': true,
      });
      gate.complete();
      await failure;
      await player;
      await d.invoke('fqapp/reader', 'keepScreenOn', {'on': false});
      await d.invoke('fqapp/native_player', 'setKeepScreenOn', {'on': false});
      expect(requests, [true, true, true, false]);
    },
  );
  test('valid Linux player operation still reports player_closed', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await expectLater(
      DesktopPlatform.instance.invoke('fqapp/native_player', 'play', null),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'player_closed'),
      ),
    );
  });
  test(
    'Linux forwards TTS errors and still rejects Android-only channels',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        ),
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('fqapp/system_tts'),
        (call) async {
          expect(call.method, 'initialize');
          throw PlatformException(code: 'TTS_ERROR', message: 'daemon missing');
        },
      );
      await LinuxPlatform.install();
      await expectLater(
        const AppMethodChannel(
          'fqapp/system_tts',
        ).invokeMethod<void>('initialize'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'TTS_ERROR'),
        ),
      );
      for (final channel in [
        'fqapp/fanqie_account',
        'fqapp/reader_system_ui',
      ]) {
        await expectLater(
          AppMethodChannel(channel).invokeMethod<void>('initialize'),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'unsupported_platform',
            ),
          ),
        );
      }
    },
  );

  test(
    'Linux media routes closed players without Android forwarding',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (_) async => null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('window_manager'),
              null,
            ),
      );
      await LinuxPlatform.install();
      await expectLater(
        const AppMethodChannel(
          'fqapp/native_player',
        ).invokeMethod<void>('play', {'id': -1}),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'player_closed',
          ),
        ),
      );
    },
  );

  test(
    'Linux uses the same absolute bundled core and visible inactive state',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(playbackAppIsActive(AppLifecycleState.inactive), isTrue);
      expect(playbackAppIsActive(AppLifecycleState.hidden), isFalse);
      if (Platform.isLinux) {
        expect(
          desktopCoreLibraryPath(),
          '${File(Platform.resolvedExecutable).parent.path}/lib/libfqapi_core.so',
        );
      }
    },
  );

  test(
    'Linux idle combines reader and player; unsupported device controls fail',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final requests = <bool>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('fqapp/desktop_session'),
        (call) async {
          expect(call.method, 'setKeepScreenOn');
          requests.add((call.arguments as Map)['on'] as bool);
          return null;
        },
      );
      final desktop = DesktopPlatform.instance;
      await desktop.invoke('fqapp/reader', 'keepScreenOn', {'on': true});
      await desktop.invoke('fqapp/native_player', 'setKeepScreenOn', {
        'on': true,
      });
      await desktop.invoke('fqapp/reader', 'stop', null);
      await desktop.invoke('fqapp/native_player', 'setKeepScreenOn', {
        'on': false,
      });
      expect(requests, [true, true, true, false]);
      for (final method in [
        'setBrightness',
        'setImmersive',
        'unknownAndroidControl',
      ]) {
        await expectLater(
          desktop.invoke('fqapp/reader', method, null),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'unsupported_platform',
            ),
          ),
        );
      }
      messenger.setMockMethodCallHandler(
        const MethodChannel('fqapp/desktop_session'),
        (_) async {
          throw PlatformException(code: 'INHIBIT_UNAVAILABLE');
        },
      );
      await expectLater(
        desktop.invoke('fqapp/reader', 'keepScreenOn', {'on': true}),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'INHIBIT_UNAVAILABLE',
          ),
        ),
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('fqapp/desktop_session'),
        (_) async => null,
      );
      await desktop.invoke('fqapp/reader', 'stop', null);
    },
  );

  test('Linux local text supports UTF-8 and UTF-16', () async {
    expect(await decodeLinuxText(Uint8List.fromList([0xe4, 0xb8, 0xad])), '中');
    expect(
      await decodeLinuxText(Uint8List.fromList([0xff, 0xfe, 0x2d, 0x4e])),
      '中',
    );
  });

  test('Linux local text supports GB18030 through system iconv', () async {
    expect(await decodeLinuxText(Uint8List.fromList([0xd6, 0xd0])), '中');
  }, skip: !Platform.isLinux);

  test(
    'Linux close waits for local initialization before flush and destroy',
    () async {
      final startup = Completer<void>();
      final destroyed = Completer<void>();
      final stopped = Completer<void>();
      final shutdown = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('fqapp/system_tts'), (
            call,
          ) async {
            expect(call.method, 'shutdown');
            shutdown.complete();
            await stopped.future;
            return null;
          });
      var flushed = false;
      LinuxPlatform.localDataInitialization = startup.future;
      LinuxPlatform.beforeClose = () async {
        flushed = true;
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            if (call.method == 'destroy') {
              expect(flushed, isTrue);
              destroyed.complete();
            }
            return null;
          });
      addTearDown(() {
        LinuxPlatform.beforeClose = null;
        LinuxPlatform.localDataInitialization = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('window_manager'),
              null,
            );
      });
      LinuxPlatform().onWindowClose();
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      startup.complete();
      await shutdown.future;
      expect(flushed, isTrue);
      expect(destroyed.isCompleted, isFalse);
      stopped.complete();
      await destroyed.future;
    },
  );

  test('platform adapters preserve typed bytes and errors', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    PlatformChannels.invoke = (channel, method, args) async {
      expect(channel, 'fqapp/library_backup');
      if (method == 'openBackup') return bytes;
      throw PlatformException(code: 'cancelled');
    };
    const channel = AppMethodChannel('fqapp/library_backup');
    expect(await channel.invokeMethod<Uint8List>('openBackup'), same(bytes));
    await expectLater(
      channel.invokeMethod<void>('saveBackup'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('TXT decoder preserves Unicode and UTF16 BOM', () {
    expect(
      decodeDesktopText(
        Uint8List.fromList([0xef, 0xbb, 0xbf, 0xe4, 0xb8, 0xad]),
      ),
      '中',
    );
    expect(
      decodeDesktopText(Uint8List.fromList([0xff, 0xfe, 0x2d, 0x4e])),
      '中',
    );
    expect(
      decodeDesktopText(Uint8List.fromList([0xfe, 0xff, 0x4e, 0x2d])),
      '中',
    );
  });

  testWidgets(
    'desktop directory filters and selects original chapter indices',
    (tester) async {
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopChapterSidebar(
              chapters: [
                for (var i = 0; i < 5; i++)
                  Chapter(itemId: '$i', title: '第 $i 章', volumeName: ''),
              ],
              currentIndex: 2,
              onSelected: (index) => selected = index,
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '3');
      await tester.pump();
      expect(find.text('第 2 章'), findsNothing);
      await tester.tap(find.text('第 3 章'));
      expect(selected, 3);
    },
  );
}
