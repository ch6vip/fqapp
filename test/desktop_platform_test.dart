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

  test('Linux TTS rejects without forwarding platform channels', () async {
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
    for (final channel in ['fqapp/system_tts']) {
      await expectLater(
        AppMethodChannel(channel).invokeMethod<void>('create'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'unsupported_platform',
          ),
        ),
      );
      expect(
        await AppEventChannel(channel).receiveBroadcastStream().toList(),
        isEmpty,
      );
    }
  });

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
