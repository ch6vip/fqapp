import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/pages/webdav_sync_page.dart';

import 'support/secure_key_storage_mock.dart';

void main() {
  late Map<String, String> secureKeys;

  setUp(() {
    secureKeys = mockSecureKeyStorage();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('backup page opens WebDAV settings and validates the address', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LibraryBackupPage()));
    final entry = find.text('WebDAV 同步');
    await tester.drag(
      find.byKey(const ValueKey('backup-scroll')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(WebDavSyncPage), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'http://example.com/',
    );
    final save = find.text('保存设置');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入 HTTPS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saves credentials in secure storage without starting disabled sync',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WebDavSyncPage()));
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'https://dav.example.com/private/',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'reader');
      await tester.enterText(find.byType(TextFormField).at(2), 'dummy-secret');
      final password = tester.widget<TextField>(
        find.descendant(
          of: find.byType(TextFormField).at(2),
          matching: find.byType(TextField),
        ),
      );
      expect(password.obscureText, isTrue);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      final save = find.text('保存设置');
      await tester.ensureVisible(save);
      await tester.tap(save);
      // The save chain now crosses two secure-storage backends (native + legacy
      // mirror), so it needs event-loop turns that pumpAndSettle alone does not
      // drive. Wait for the message instead of assuming one settle is enough.
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.text('设置已安全保存').evaluate().isNotEmpty) break;
      }
      expect(find.text('设置已安全保存'), findsOneWidget);
      final secure = secureKeys;
      final settings = jsonDecode(secure['fqapp.webdav.config.v1']!) as Map;
      expect(settings['password'], 'dummy-secret');
      expect(settings['enabled'], isFalse);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
