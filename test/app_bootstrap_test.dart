import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/main.dart' as app;
import 'package:fqapp/services/library_store.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('retrying initialization retains existing Hive history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final tempRoot = Directory.systemTemp.absolute;
    late Directory directory;
    late Box<dynamic> history;
    final record = {
      'id': 'kept',
      'kind': 'book',
      'title': '已保存作品',
      'chapterId': 'chapter-7',
      'episode': 6,
      'position': 73.5,
    };
    await tester.runAsync(() async {
      directory = await tempRoot.createTemp('fqapp-bootstrap-');
      Hive.init(directory.path);
      history = await Hive.openBox<dynamic>('history');
      await Hive.openBox<dynamic>('read_time');
      await history.put('kept', record);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await Hive.close();
        if (directory.absolute.parent.path != tempRoot.path) {
          throw StateError('Temporary directory escaped its parent');
        }
        await directory.delete(recursive: true);
      });
    });
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: app.AppBootstrap(
          initializer: () async {
            attempts++;
            await LibraryStore.instance.init();
            if (attempts == 1) throw StateError('transient startup failure');
          },
          child: const Text('ready'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法读取本地数据'), findsOneWidget);
    expect(history.get('kept'), record);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('ready'), findsOneWidget);
    expect(attempts, 2);
    expect(history.get('kept'), record);
    expect(
      (await LibraryStore.instance.historyEntry('kept'))?['position'],
      73.5,
    );
  });

  testWidgets('bootstrap mounts business pages only after a successful retry', (
    tester,
  ) async {
    final first = Completer<void>();
    final retry = Completer<void>();
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: app.AppBootstrap(
          initializer: () => ++attempts == 1 ? first.future : retry.future,
          child: const Text('ready'),
        ),
      ),
    );
    expect(find.text('ready'), findsNothing);
    expect(attempts, 1);
    first.completeError(StateError('cannot open stored data'));
    await tester.pump();
    expect(find.text('无法读取本地数据'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    button.onPressed!();
    button.onPressed!();
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('ready'), findsNothing);
    retry.complete();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('disposing a pending bootstrap ignores its late completion', (
    tester,
  ) async {
    final initialized = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: app.AppBootstrap(
          initializer: () => initialized.future,
          child: const Text('ready'),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    initialized.completeError(StateError('late initialization error'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('main renders a retryable screen when the data directory fails', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    var attempts = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      attempts++;
      throw PlatformException(
        code: 'unavailable',
        message: 'private-storage-path',
      );
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    app.main();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('无法读取本地数据'), findsOneWidget);
    expect(find.textContaining('private-storage-path'), findsNothing);
    expect(attempts, 1);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('无法读取本地数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
