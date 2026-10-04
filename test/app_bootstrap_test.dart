import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/main.dart' as app;
import 'package:fqapp/services/app_log.dart';
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
      // 已看集 box 也在 LibraryStore.init 里开箱（F07），同样要预开，
      // 否则 openBox 落在 widget 测试的 fake-async 路径上不会完成。
      await Hive.openBox<dynamic>('watched_episodes');
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
    messenger.setMockMethodCallHandler(channel, (call) async {
      // 只统计引导用的文档目录（Hive.initFlutter）；应用日志落盘会另探一次
      // 支持目录（getApplicationSupportDirectory），与本用例的「重试一次」无关。
      if (call.method == 'getApplicationDocumentsDirectory') attempts++;
      throw PlatformException(
        code: 'unavailable',
        message: 'private-storage-path',
      );
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    app.main();
    // main() 接管了 debugPrint 与 FlutterError.onError，把应用日志收进缓冲。
    // flutter_test 会在测试体结束时断言这两个 foundation 调试变量未被改动，
    // 所以必须在**测试体内**还原（addTearDown 跑在不变量检查之后，太晚）。
    try {
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
    } finally {
      await AppLog.instance.resetForTest();
    }
  });
}
