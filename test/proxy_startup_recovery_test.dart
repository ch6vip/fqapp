import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/main.dart';
import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/services/network_proxy_preferences.dart';
import 'package:fqapp/widgets/settings/core_proxy_settings_panel.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets(
    'Windows cold start with corrupt proxy can explicitly reset direct and retry',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({
        NetworkProxyPreferences.key: jsonEncode({
          'enabled': true,
          'url': 'broken',
        }),
      });
      final pending = Completer<void>();
      var starts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: RootShell(
            backendStarter: () async {
              starts++;
              await NetworkProxyPreferences.instance.load();
              await pending.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('启动失败'), findsOneWidget);
      await tester.tap(find.text('重置代理为直连并重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect((await NetworkProxyPreferences.instance.load()).enabled, isFalse);
      expect(starts, 2);
      expect(find.text('正在启动本地服务...'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets('proxy settings are Windows-only on $platform', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(const MaterialApp(home: ApiServicePage()));
      await tester.pumpAndSettle();
      expect(
        find.byType(CoreProxySettingsPanel),
        platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
