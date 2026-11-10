import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fqapp/services/app_theme.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/services/local_proxy_discovery.dart';
import 'package:fqapp/services/network_proxy_preferences.dart';
import 'package:fqapp/widgets/settings/core_proxy_settings_panel.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> open(
    WidgetTester tester, {
    Future<List<LocalProxyCandidate>> Function()? discover,
    Future<void> Function()? apply,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CoreProxySettingsPanel(
              discover: discover ?? () async => [],
              applyChanges: apply ?? () async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'detection runs only on click and selecting a candidate fills proxy for explicit save',
    (tester) async {
      var detections = 0;
      var applied = 0;
      await open(
        tester,
        discover: () async {
          detections++;
          return [
            const LocalProxyCandidate(
              url: 'http://127.0.0.1:17890',
              label: 'HTTP · 127.0.0.1:17890',
            ),
          ];
        },
        apply: () async {
          applied++;
        },
      );
      expect(detections, 0);
      await tester.tap(find.text('检测本机代理'));
      await tester.pumpAndSettle();
      expect(detections, 1);
      await tester.tap(find.text('HTTP · 127.0.0.1:17890'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'http://127.0.0.1:17890',
      );
      expect((await NetworkProxyPreferences.instance.load()).enabled, isFalse);
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(applied, 1);
      expect((await NetworkProxyPreferences.instance.load()).toJson(), {
        'enabled': true,
        'url': 'http://127.0.0.1:17890',
      });
      expect(find.text('已应用，核心请求使用指定代理'), findsOneWidget);
    },
  );

  testWidgets(
    'no candidates offers manual entry and invalid address does not restart',
    (tester) async {
      var applied = 0;
      await open(
        tester,
        apply: () async {
          applied++;
        },
      );
      await tester.tap(find.text('检测本机代理'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未发现'), findsOneWidget);
      await tester.tap(find.text('使用指定代理'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bad address');
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(applied, 0);
      expect((await NetworkProxyPreferences.instance.load()).enabled, isFalse);
      expect(find.textContaining('请输入带协议和端口'), findsOneWidget);
    },
  );

  testWidgets('failed restart remains recoverable by saving direct mode', (
    tester,
  ) async {
    var fail = true;
    await open(
      tester,
      apply: () async {
        if (fail) throw StateError('down');
      },
    );
    await tester.tap(find.text('使用指定代理'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'http://127.0.0.1:7890');
    await tester.tap(find.text('保存并应用'));
    await tester.pumpAndSettle();
    expect(find.textContaining('核心启动失败'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('使用指定代理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并应用'));
    await tester.pumpAndSettle();
    expect((await NetworkProxyPreferences.instance.load()).enabled, isFalse);
    expect(find.text('已应用，核心请求直接连接'), findsOneWidget);
  });

  testWidgets('slow detection shows progress and prevents overlapping calls', (
    tester,
  ) async {
    final pending = Completer<List<LocalProxyCandidate>>();
    var calls = 0;
    await open(
      tester,
      discover: () {
        calls++;
        return pending.future;
      },
    );
    await tester.tap(find.text('检测本机代理'));
    await tester.pump();
    expect(find.text('正在检测…'), findsOneWidget);
    expect(calls, 1);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('检测本机代理'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'proxy form stays usable at narrow width and large text in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(360, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (Platform.environment['FQAPP_CAPTURE_PROXY_UI'] == '1') {
          final loader = FontLoader('NotoSerifSC')
            ..addFont(rootBundle.load('assets/fonts/NotoSerifSC-Regular.otf'));
          await loader.load();
        }
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.createTheme(brightness).copyWith(
              textTheme: AppTheme.createTheme(brightness).textTheme.apply(
                fontFamily:
                    Platform.environment['FQAPP_CAPTURE_PROXY_UI'] == '1'
                    ? 'NotoSerifSC'
                    : null,
              ),
            ),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 1100),
                textScaler: TextScaler.linear(1.3),
              ),
              child: Scaffold(
                body: RepaintBoundary(
                  key: boundaryKey,
                  child: SingleChildScrollView(
                    child: CoreProxySettingsPanel(
                      discover: () async => [
                        const LocalProxyCandidate(
                          url: 'http://127.0.0.1:17890',
                          label: 'HTTP · 127.0.0.1:17890',
                        ),
                      ],
                      applyChanges: () async {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('检测本机代理'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('HTTP · 127.0.0.1:17890'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('保存并应用'));
        await tester.tap(find.text('保存并应用'));
        await tester.pumpAndSettle();
        expect(find.text('已应用，核心请求使用指定代理'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (Platform.environment['FQAPP_CAPTURE_PROXY_UI'] == '1') {
          await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('.dart_tool/proxy-ui').create(recursive: true);
            await File(
              '.dart_tool/proxy-ui/${brightness.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
  }
}
