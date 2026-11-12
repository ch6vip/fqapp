import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/fanqie_library_capture.dart';
import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/fanqie_history_import_page.dart';
import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/pages/log_viewer_page.dart';
import 'package:fqapp/pages/text_replacement_page.dart';
import 'package:fqapp/services/app_log.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/book_txt_export.dart';
import 'package:fqapp/services/fanqie_library_capture_service.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/settings/settings_archive_page.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';

import 'support/app_ui_host.dart';

/// Real actions behind the secondary settings pages under both presentations:
/// backup export/restore, 番茄 capture progress/cancel and the final merge,
/// replacement preview + save, and log copy/export. The pages only differ in
/// chrome, so the same handlers must drive both shells.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppLog.instance.resetForTest();
    einkModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
    directory = await Directory.systemTemp.createTemp(
      'fqapp-secondary-actions-',
    );
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
  });

  tearDown(() async {
    AppLog.instance.resetForTest();
    einkModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
    await ShelfGroupStore.instance.whenIdle();
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temp directory cleanup is noise.
    }
  });

  Future<AppThemeStyleStore> pumpStyled(
    WidgetTester tester,
    Widget page, {
    AppThemeStyle style = AppThemeStyle.classic,
    Size size = const Size(500, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = AppThemeStyleStore()..value = style;
    addTearDown(store.dispose);
    await tester.pumpWidget(AppUiHost(store: store, home: page));
    await tester.pumpAndSettle();
    return store;
  }

  /// Real Hive/isolate work cannot complete inside the fake-async test zone.
  Future<void> tapAndWait(
    WidgetTester tester,
    Finder target,
    Finder expected,
  ) async {
    await tester.runAsync(() async {
      await tester.tap(target);
    });
    for (var i = 0; i < 300; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (expected.evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  group('backup real actions', () {
    testWidgets('经典导出备份写入真实快照并提示保存', (tester) async {
      await tester.runAsync(() async {
        await ShelfStore.instance.add(
          MediaItem(
            id: '9001',
            title: '导出测试书',
            cover: '',
            author: '作者',
            badge: '',
            ep: '',
            kind: 'book',
          ),
        );
        await LibraryStore.instance.addHistory({
          'id': '9001',
          'kind': 'book',
          'title': '导出测试书',
          'time': 1,
        });
      });

      const channel = MethodChannel('fqapp/library_backup');
      Uint8List? savedBytes;
      String? savedName;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'saveBackup') {
          final args = call.arguments as Map;
          savedBytes = args['bytes'] as Uint8List;
          savedName = args['name'] as String?;
          return true;
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      await pumpStyled(tester, const LibraryBackupPage());

      await tapAndWait(
        tester,
        find.text('导出备份'),
        find.textContaining('备份文件已保存'),
      );

      expect(find.textContaining('备份文件已保存'), findsOneWidget);
      expect(savedName, startsWith('fqapp-backup-'));
      final backup = LibraryBackup.decode(savedBytes!);
      expect(backup.shelf.map((record) => record.item.id), contains('9001'));
      expect(backup.history, hasLength(1));
      // Classic keeps the primary action in the fixed bottom bar; it only
      // appears for a preview or a busy operation.
      expect(find.byType(SettingsScaffold), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('档案预览后点击确认恢复，真实写入本机并报告分组', (tester) async {
      const channel = MethodChannel('fqapp/library_backup');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'openBackup') return _groupedBackupBytes();
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      await pumpStyled(
        tester,
        const LibraryBackupPage(),
        style: AppThemeStyle.archive,
      );
      expect(find.byType(SettingsArchivePage), findsOneWidget);

      await tapAndWait(tester, find.text('从备份文件恢复'), find.text('恢复预览'));
      expect(find.text('分组'), findsOneWidget);

      await tapAndWait(
        tester,
        find.text('确认恢复到本机'),
        find.textContaining('恢复完成'),
      );

      expect(find.textContaining('2 个分组（3 条分类归属）'), findsOneWidget);
      expect(
        ShelfStore.instance.records().map((record) => record.item.id),
        contains('1'),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('番茄 import real actions', () {
    testWidgets('Android 历史文件导入并合并到书架和历史', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        const channel = MethodChannel('fqapp/library_backup');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'openBackup') return _fanqieHistoryBytes();
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );

        await pumpStyled(tester, const FanqieHistoryImportPage());

        await tapAndWait(
          tester,
          find.text('从历史文件导入'),
          find.textContaining('导入预览'),
        );
        expect(find.text('历史作品 0'), findsOneWidget);

        // Classic keeps the merge action in its fixed bottom bar.
        await tapAndWait(
          tester,
          find.textContaining('导入 6 本到书架和历史'),
          find.textContaining('已合并书架'),
        );

        expect(find.textContaining('已合并书架'), findsOneWidget);
        expect(
          ShelfStore.instance.records().map((record) => record.item.id),
          contains('100'),
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    for (final style in AppThemeStyle.values) {
      testWidgets('Linux ${style.name} 历史 JSON 预览切主题后确认合并保留较新进度', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          await tester.runAsync(() async {
            await LibraryStore.instance.addHistory({
              'id': '100',
              'kind': 'book',
              'title': '本机较新记录',
              'time': 9000,
              'chapterId': 'local-chapter',
              'episode': 7,
              'progress': 0.6,
            });
          });
          const channel = MethodChannel('fqapp/library_backup');
          final calls = <String>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async {
              calls.add(call.method);
              if (call.method == 'openBackup') return _fanqieHistoryBytes();
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

          final store = await pumpStyled(
            tester,
            const FanqieHistoryImportPage(),
            style: style,
          );
          await tapAndWait(
            tester,
            find.text('从历史文件导入'),
            find.textContaining('导入预览'),
          );
          expect(find.text('历史作品 0'), findsOneWidget);
          expect(ShelfStore.instance.records(), isEmpty, reason: '预览不能先写入书架');
          expect(LibraryStore.instance.historySnapshot(), hasLength(1));
          final state = tester.state(find.byType(FanqieHistoryImportPage));
          final scrollable = find.descendant(
            of: find.byKey(const ValueKey('fanqie-import-scroll')),
            matching: find.byType(Scrollable),
          );
          final merge = find.textContaining('导入 6 本到书架和历史');
          for (final next in [
            style == AppThemeStyle.classic
                ? AppThemeStyle.archive
                : AppThemeStyle.classic,
            style,
          ]) {
            store.value = next;
            await tester.pumpAndSettle();
            expect(
              tester.state(find.byType(FanqieHistoryImportPage)),
              same(state),
            );
            await tester.scrollUntilVisible(merge, 200, scrollable: scrollable);
            expect(merge, findsOneWidget);
            expect(
              find.byKey(const ValueKey('fanqie-merge')),
              next == AppThemeStyle.archive ? findsOneWidget : findsNothing,
            );
            expect(ShelfStore.instance.records(), isEmpty);
          }

          // Classic keeps the merge action in its fixed bar; archive uses the inline action.
          await tester.ensureVisible(merge);
          await tapAndWait(tester, merge, find.textContaining('已合并书架'));
          expect(find.textContaining('已合并书架'), findsOneWidget);
          expect(
            ShelfStore.instance.records().map((record) => record.item.id),
            contains('100'),
          );
          expect(ShelfStore.instance.records(), hasLength(6));
          final history = LibraryStore.instance.historySnapshot();
          expect(history, hasLength(6));
          final local = history.singleWhere((record) => record['id'] == '100');
          expect(local['time'], 9000);
          expect(local['chapterId'], 'local-chapter');
          expect(local['episode'], 7);
          expect(local['progress'], 0.6);
          // Reusing the same local file must not duplicate shelf/history records.
          final pick = find.byKey(const ValueKey('fanqie-pick'));
          await tester.scrollUntilVisible(pick, -240, scrollable: scrollable);
          await tapAndWait(tester, pick, find.textContaining('导入预览'));
          await tester.scrollUntilVisible(merge, 200, scrollable: scrollable);
          await tapAndWait(tester, merge, find.textContaining('已合并书架'));
          expect(ShelfStore.instance.records(), hasLength(6));
          expect(LibraryStore.instance.historySnapshot(), hasLength(6));
          expect(
            LibraryStore.instance.historySnapshot().singleWhere(
              (record) => record['id'] == '100',
            ),
            local,
          );
          expect(calls, ['openBackup', 'openBackup']);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('采集显示进度并可取消，取消后不导入', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final collector = _CancellingCaptureService();
        addTearDown(collector.dispose);

        await pumpStyled(
          tester,
          FanqieHistoryImportPage(collector: collector),
          style: AppThemeStyle.archive,
        );

        await tester.tap(find.text('从番茄账号读取'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(collector.collectCalls, 1);
        expect(find.text('正在读取书架列表…'), findsOneWidget);
        // The archive shell reports progress inline with a cancel action.
        expect(find.text('取消读取'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsWidgets);

        await tester.tap(find.text('取消读取'));
        await tester.pumpAndSettle();
        expect(find.text('读取已取消，未导入本机'), findsOneWidget);
        expect(find.text('取消读取'), findsNothing);
        expect(ShelfStore.instance.records(), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('text replacement real actions', () {
    testWidgets('经典规则编辑器预览并保存真实规则', (tester) async {
      final replacement = TextReplacementStore();
      await replacement.load();
      await pumpStyled(
        tester,
        TextReplacementPage(store: replacement),
        size: const Size(400, 900),
      );

      await tester.tap(find.byKey(const ValueKey('replacement-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('replacement-pattern')),
        '漂亮国',
      );
      await tester.enterText(
        find.byKey(const ValueKey('replacement-value')),
        '美国',
      );
      await tester.enterText(find.widgetWithText(TextField, '测试文本'), '漂亮国的书');
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.text('预览本条规则'));
      });
      for (var i = 0; i < 300; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.text('美国的书').evaluate().isNotEmpty) break;
      }
      await tester.pump();
      expect(find.text('美国的书'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(replacement.snapshot.rules.single.pattern, '漂亮国');
      expect(find.byKey(const ValueKey('replacement-edit-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('log real actions', () {
    testWidgets('经典复制筛选结果写入剪贴板', (tester) async {
      AppLog.i('boot', '待复制的日志');
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpStyled(tester, const LogViewerPage());

      await tester.tap(find.byTooltip('日志操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制筛选结果'));
      await tester.pumpAndSettle();

      expect(copied, contains('待复制的日志'));
      expect(find.textContaining('已复制 1 条日志'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('档案导出筛选结果交给 TXT sink', (tester) async {
      AppLog.i('boot', '待导出的日志');
      final sink = _RecordingSink();
      await pumpStyled(
        tester,
        LogViewerPage(exportSink: sink),
        style: AppThemeStyle.archive,
      );

      await tester.tap(find.byTooltip('日志操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出筛选结果'));
      await tester.pumpAndSettle();

      expect(sink.fileName, startsWith('fqapp-app-logs-'));
      expect(sink.text, contains('待导出的日志'));
      expect(find.textContaining('已导出 1 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

Uint8List _groupedBackupBytes() {
  final backup = LibraryBackup.capture(
    shelf: [
      ShelfRecord(
        item: MediaItem(
          id: '1',
          title: '作品',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
        addedAt: DateTime(2020),
      ),
    ],
    history: [
      {'id': '1', 'kind': 'book'},
    ],
    watched: {},
    groups: {
      'version': 1,
      'groups': {
        'g1-a': {'name': '想读', 'at': 1, 'deleted': false},
        'g2-b': {'name': '在读', 'at': 2, 'deleted': false},
      },
      'assignments': {
        'book:1': {'group': 'g1-a', 'at': 1},
        'book:2': {'group': 'g1-a', 'at': 2},
        'book:3': {'group': 'g2-b', 'at': 3},
      },
    },
  );
  return backup.encode();
}

Uint8List _fanqieHistoryBytes() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'code': 0,
      'data': {
        'has_more': false,
        'next_offset': 0,
        'data_list': [
          for (var i = 0; i < 6; i++)
            {
              'book_id': '10$i',
              'book_type': 0,
              'book_name': '历史作品 $i',
              'read_timestamp_ms': 1000 + i,
            },
        ],
      },
    }),
  ),
);

/// Capture service that reports one progress message and then waits for the
/// page's cancel action.
class _CancellingCaptureService extends FanqieLibraryCaptureService {
  int collectCalls = 0;
  final _progress = ValueNotifier<String?>(null);

  void dispose() => _progress.dispose();

  @override
  Future<FanqieLibraryCapture?> latest() async => null;

  @override
  Future<bool> save(FanqieLibraryCapture capture) async => true;

  @override
  Future<FanqieLibraryCapture?> collect(
    BackendRequest request,
    void Function(String) progress, {
    bool? dark,
    bool eink = false,
  }) async {
    collectCalls++;
    progress('正在读取书架列表…');
    _progress.value = '正在读取书架列表…';
    if (request.isCancelled) throw BackendRequestAborted('读取已取消');
    await request.whenCancelled;
    throw BackendRequestAborted('读取已取消');
  }
}

class _RecordingSink implements TxtSink {
  String? fileName;
  String? text;

  @override
  Future<ExportTarget> saveText({
    required String fileName,
    required String text,
  }) async {
    this.fileName = fileName;
    this.text = text;
    return const ExportTarget(path: '/tmp/logs.txt', isPublic: true);
  }
}
