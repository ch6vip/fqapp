import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/book_txt_export.dart';
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

  test('Linux backup selection saves bytes, reads and cancels', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const selector = MethodChannel('plugins.flutter.io/file_selector');
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => null,
    );
    final directory = await Directory.systemTemp.createTemp('linux-backup-');
    addTearDown(() async {
      messenger.setMockMethodCallHandler(selector, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
      await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/备份.json');
    var cancelled = false;
    var unavailable = false;
    messenger.setMockMethodCallHandler(selector, (call) async {
      if (unavailable) throw PlatformException(code: 'dialog_unavailable');
      if (cancelled) return null;
      final args = call.arguments as Map;
      expect((args['acceptedTypeGroups'] as List).single['extensions'], [
        'json',
      ]);
      if (call.method == 'getSavePath') {
        expect(args['suggestedName'], 'backup.json');
        return file.path;
      }
      expect(call.method, 'openFile');
      return [file.path];
    });
    await LinuxPlatform.install();
    const channel = AppMethodChannel('fqapp/library_backup');
    final bytes = Uint8List.fromList([123, 125]);
    expect(
      await channel.invokeMethod<bool>('saveBackup', {
        'name': 'backup.json',
        'bytes': bytes,
      }),
      isTrue,
    );
    expect(await file.readAsBytes(), bytes);
    expect(await channel.invokeMethod<Uint8List>('openBackup'), bytes);
    cancelled = true;
    expect(
      await channel.invokeMethod<bool>('saveBackup', {
        'name': 'backup.json',
        'bytes': Uint8List(0),
      }),
      isFalse,
    );
    expect(await channel.invokeMethod<Uint8List>('openBackup'), isNull);
    expect(await file.readAsBytes(), bytes);
    cancelled = false;
    unavailable = true;
    await expectLater(
      channel.invokeMethod<Uint8List>('openBackup'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'dialog_unavailable',
        ),
      ),
    );
    await expectLater(
      channel.invokeMethod<void>('storeFanqieCapture'),
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
    'Linux TXT sink saves UTF-8 and reports cancellation and failures',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const selector = MethodChannel('plugins.flutter.io/file_selector');
      const window = MethodChannel('window_manager');
      messenger.setMockMethodCallHandler(window, (_) async => null);
      final directory = await Directory.systemTemp.createTemp(
        'linux-text-export-',
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(selector, null);
        messenger.setMockMethodCallHandler(window, null);
        await directory.delete(recursive: true);
      });
      final file = File('${directory.path}/小说与日志.txt');
      String? selectedPath = file.path;
      var unavailable = false;
      messenger.setMockMethodCallHandler(selector, (call) async {
        expect(call.method, 'getSavePath');
        final args = call.arguments as Map;
        expect(args['suggestedName'], '导出.txt');
        expect((args['acceptedTypeGroups'] as List).single['extensions'], [
          'txt',
        ]);
        if (unavailable) {
          throw PlatformException(
            code: 'dialog_unavailable',
            message: '选择器不可用',
          );
        }
        return selectedPath;
      });
      await LinuxPlatform.install();
      const sink = PlatformTxtSink();
      final result = await sink.saveText(fileName: '导出.txt', text: '正文\n日志 😀');
      expect(result.path, file.path);
      expect(result.isPublic, isTrue);
      expect(await file.readAsString(), '正文\n日志 😀');
      selectedPath = null;
      await expectLater(
        sink.saveText(fileName: '导出.txt', text: '取消后不得覆盖'),
        throwsA(
          isA<ExportWriteException>().having(
            (e) => e.message,
            'message',
            '已取消保存',
          ),
        ),
      );
      expect(await file.readAsString(), '正文\n日志 😀');
      unavailable = true;
      await expectLater(
        sink.saveText(fileName: '导出.txt', text: '失败'),
        throwsA(
          isA<ExportWriteException>().having(
            (e) => e.message,
            'message',
            '选择器不可用',
          ),
        ),
      );
      unavailable = false;
      selectedPath = directory.path;
      await expectLater(
        sink.saveText(fileName: '导出.txt', text: '不能写入目录'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        const AppMethodChannel(
          'fqapp/downloads',
        ).invokeMethod<void>('deleteAll'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'unsupported_platform',
          ),
        ),
      );
    },
  );

  for (final backup in [true, false]) {
    testWidgets(
      'Linux ${backup ? 'backup' : 'text'} requires explicit overwrite confirmation',
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const selector = MethodChannel('plugins.flutter.io/file_selector');
        const window = MethodChannel('window_manager');
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('overwrite-'),
        ))!;
        final file = File(
          '${directory.path}/export.${backup ? 'json' : 'txt'}',
        );
        await tester.runAsync(() => file.writeAsString('original data'));
        messenger.setMockMethodCallHandler(window, (_) async => null);
        messenger.setMockMethodCallHandler(selector, (_) async => file.path);
        addTearDown(() async {
          messenger.setMockMethodCallHandler(selector, null);
          messenger.setMockMethodCallHandler(window, null);
          await directory.delete(recursive: true);
        });
        await tester.runAsync(LinuxPlatform.install);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: DesktopPlatform.navigatorKey,
            home: const Scaffold(),
          ),
        );
        Object? result;
        Object? failure;
        Future<void>? saving;
        Future<void> startSave() async {
          result = null;
          failure = null;
          await tester.runAsync(() async {
            saving =
                AppMethodChannel(
                      backup ? 'fqapp/library_backup' : 'fqapp/downloads',
                    )
                    .invokeMethod<dynamic>(
                      backup ? 'saveBackup' : 'saveText',
                      backup
                          ? {
                              'name': 'backup.json',
                              'bytes': Uint8List.fromList([123, 125]),
                            }
                          : {'fileName': 'log.txt', 'text': 'export log 😀'},
                    )
                    .then<void>(
                      (value) => result = value,
                      onError: (Object error) {
                        failure = error;
                      },
                    );
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await tester.pumpAndSettle();
        }

        for (final dismiss in ['取消', 'barrier']) {
          await startSave();
          expect(find.text('覆盖已有文件？'), findsOneWidget);
          expect(find.textContaining(file.path), findsOneWidget);
          expect(await tester.runAsync(file.readAsString), 'original data');
          if (dismiss == '取消') {
            await tester.tap(find.text('取消'));
          } else {
            await tester.tapAt(const Offset(5, 5));
          }
          await tester.pumpAndSettle();
          await tester.runAsync(() => saving!);
          if (backup) {
            expect(result, isFalse);
            expect(failure, isNull);
          } else {
            expect(
              failure,
              isA<PlatformException>().having(
                (e) => e.code,
                'code',
                'cancelled',
              ),
            );
          }
          expect(await tester.runAsync(file.readAsString), 'original data');
        }

        await startSave();
        await tester.tap(find.text('覆盖'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => saving!);
        expect(failure, isNull);
        expect(result, backup ? true : {'path': file.path, 'public': true});
        expect(
          await tester.runAsync(file.readAsString),
          backup ? '{}' : 'export log 😀',
        );

        await startSave();
        await tester.runAsync(() async {
          final replacement = File('${directory.path}/replacement');
          await replacement.writeAsString('replacement must survive');
          await replacement.rename(file.path);
        });
        await tester.tap(find.text('覆盖'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => saving!);
        expect(
          failure,
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'file_changed',
          ),
        );
        expect(
          await tester.runAsync(file.readAsString),
          'replacement must survive',
        );

        await startSave();
        await tester.runAsync(
          () => file.writeAsString('edited during confirmation'),
        );
        await tester.tap(find.text('覆盖'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => saving!);
        expect(
          failure,
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'file_changed',
          ),
        );
        expect(
          await tester.runAsync(file.readAsString),
          'edited during confirmation',
        );

        await tester.runAsync(() async {
          final target = File('${directory.path}/link-target');
          await target.writeAsString('symlink target must survive');
          await file.delete();
          await Link(file.path).create(target.path);
        });
        await startSave();
        await tester.runAsync(() => saving!);
        expect(failure, isA<FileSystemException>());
        expect(find.text('覆盖已有文件？'), findsNothing);
        expect(
          await tester.runAsync(file.readAsString),
          'symlink target must survive',
        );
        await tester.runAsync(() async {
          await file.delete();

          await file.writeAsString('no navigator must preserve this');
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await startSave();
        await tester.runAsync(() => saving!);
        expect(
          failure,
          isA<PlatformException>().having((e) => e.code, 'code', 'not_ready'),
        );
        expect(
          await tester.runAsync(file.readAsString),
          'no navigator must preserve this',
        );
      },
      variant: TargetPlatformVariant({TargetPlatform.linux}),
    );
  }

  test('Windows saves existing files using native selector approval', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const selector = MethodChannel('plugins.flutter.io/file_selector');
    final directory = await Directory.systemTemp.createTemp('windows-save-');
    final file = File('${directory.path}/log.txt');
    await file.writeAsString('old log');
    messenger.setMockMethodCallHandler(selector, (_) async => file.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(selector, null);
      await directory.delete(recursive: true);
    });
    expect(
      await DesktopPlatform.instance.invoke('fqapp/downloads', 'saveText', {
        'fileName': 'log.txt',
        'text': 'new log',
      }),
      {'path': file.path, 'public': true},
    );
    expect(await file.readAsString(), 'new log');
  });

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
