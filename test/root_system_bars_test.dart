import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';

void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-system-bars-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final mode in ['light', 'dark', 'oled']) {
    testWidgets(
      '$mode shell keeps the navigation area in the page theme',
      (tester) async {
        final dark = mode != 'light';
        themeModeNotifier.value = dark ? ThemeMode.dark : ThemeMode.light;
        oledModeNotifier.value = mode == 'oled';
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 800);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
        final styles = <Map<dynamic, dynamic>>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
              styles.add(call.arguments as Map<dynamic, dynamic>);
            }
            return null;
          },
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
          tester.view.reset();
          themeModeNotifier.value = ThemeMode.system;
          oledModeNotifier.value = false;
        });

        // Make every test observe a fresh platform update, even when styles match.
        SystemChrome.setSystemUIOverlayStyle(
          const SystemUiOverlayStyle(systemNavigationBarColor: Colors.pink),
        );
        await tester.pump();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              homeProvider.overrideWith(
                () => HomeNotifier(
                  homepageLoader:
                      ({
                        int tabType = 2,
                        int offset = 0,
                        String? sessionId,
                      }) async => const HomepagePage(
                        items: [],
                        nextOffset: null,
                        sessionId: null,
                      ),
                  searchLoader: (query, {int page = 1}) async => [],
                ),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.createTheme(
                dark ? Brightness.dark : Brightness.light,
                oledMode: mode == 'oled',
              ),
              home: RootShell(backendStarter: () async {}),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final canvas = switch (mode) {
          'light' => 0xFFF6F6F6,
          'dark' => 0xFF151517,
          _ => 0xFF000000,
        };
        for (final label in ['首页', '书架', '我的', '首页']) {
          await tester.tap(
            find.descendant(
              of: find.byType(NavigationBar),
              matching: find.text(label),
            ),
          );
          await tester.pumpAndSettle();
          final style = styles.last;
          expect(style['systemNavigationBarColor'], canvas, reason: label);
          expect(
            style['systemNavigationBarIconBrightness'],
            dark ? 'Brightness.light' : 'Brightness.dark',
            reason: label,
          );
          expect(
            style['systemNavigationBarContrastEnforced'],
            false,
            reason:
                '$label must not get a system contrast scrim over its canvas',
          );
          expect(tester.takeException(), isNull);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
