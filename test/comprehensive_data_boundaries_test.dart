import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/main.dart' as app;
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/digg_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  for (final scenario in <({Object value, ThemeMode expected})>[
    (value: 1, expected: ThemeMode.system),
    (value: true, expected: ThemeMode.system),
    (value: <String>['dark'], expected: ThemeMode.system),
    (value: 'unknown-mode', expected: ThemeMode.system),
    (value: 'light', expected: ThemeMode.light),
    (value: 'dark', expected: ThemeMode.dark),
    (value: 'system', expected: ThemeMode.system),
  ]) {
    testWidgets(
      'theme preference ${scenario.value} restores without blocking local data',
      (tester) async {
        SharedPreferences.setMockInitialValues({themeModeKey: scenario.value});
        themeModeNotifier.value = ThemeMode.dark;
        final tempRoot = Directory.systemTemp.absolute;
        late Directory directory;
        const record = {
          'id': 'kept-book',
          'kind': 'book',
          'title': '已保存作品',
          'chapterId': 'chapter-7',
          'episode': 6,
          'position': 73.5,
        };
        await tester.runAsync(() async {
          directory = await tempRoot.createTemp('fqapp-theme-boundary-');
          Hive.init(directory.path);
          final history = await Hive.openBox<dynamic>('history');
          await Hive.openBox<dynamic>('read_time');
          // The bootstrap also opens the 加入书架 box; pre-opening it here keeps
          // that openBox off the widget test's fake-async file I/O path, which
          // would never complete.
          await ShelfStore.instance.init();
          // 同理，短剧 feed 的 点赞 box 也在 bootstrap 里开箱。
          await DiggStore.instance.init();
          await history.put('kept-book', record);
        });
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => directory.path,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          messenger.setMockMethodCallHandler(channel, null);
          themeModeNotifier.value = ThemeMode.system;
          await tester.runAsync(() async {
            await Hive.close();
            if (directory.absolute.parent.path != tempRoot.path) {
              throw StateError('Temporary directory escaped its parent');
            }
            await directory.delete(recursive: true);
          });
        });

        await tester.pumpWidget(
          const MaterialApp(
            home: app.AppBootstrap(child: Text('local data ready')),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('local data ready'), findsOneWidget);
        expect(themeModeNotifier.value, scenario.expected);
        expect(
          (await SharedPreferences.getInstance()).get(themeModeKey),
          scenario.value,
        );
        expect(
          (await LibraryStore.instance.historyEntry('kept-book'))?['position'],
          73.5,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  group('clearing a partially migrated library', () {
    final tempRoot = Directory.systemTemp.absolute;
    final store = LibraryStore.instance;
    late Directory directory;

    setUp(() async {
      directory = await tempRoot.createTemp('fqapp-migration-clear-');
      Hive.init(directory.path);
      final oversizedId = 'x' * 256;
      // Hive rejects the oversized key after an earlier valid entry has been
      // persisted. This is an actual partial migration, with no fake store.
      SharedPreferences.setMockInitialValues({
        themeModeKey: 'dark',
        'hist': jsonEncode([
          {'id': oversizedId, 'title': 'invalid key'},
          {'id': 'kept-book', 'kind': 'book', 'position': 73.5},
        ]),
        'read_time_map': jsonEncode({
          'kept-book': {'2026-9-17': 30.0},
          oversizedId: {'2026-9-17': 10.0},
        }),
      });
      await store.init();
      expect(await store.historyEntry('kept-book'), isNotNull);
      expect(store.readTimeSnapshot()['kept-book'], {'2026-9-17': 30.0});
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('hist'), isTrue);
      expect(preferences.containsKey('read_time_map'), isTrue);
    });

    tearDown(() async {
      await Hive.close();
      if (directory.absolute.parent.path != tempRoot.path) {
        throw StateError('Temporary directory escaped its parent');
      }
      await directory.delete(recursive: true);
    });

    for (final clearAll in [false, true]) {
      test(
        '${clearAll ? 'reading data' : 'history'} stays cleared after reopening',
        () async {
          if (clearAll) {
            await store.clearReadingData();
          } else {
            await store.clearHistory();
          }
          expect(store.historySnapshot(), isEmpty);
          expect(
            store.readTimeSnapshot(),
            clearAll
                ? isEmpty
                : equals({
                    'kept-book': {'2026-9-17': 30.0},
                  }),
          );

          await Hive.close();
          await store.init();

          expect(store.historySnapshot(), isEmpty);
          expect(
            store.readTimeSnapshot(),
            clearAll
                ? isEmpty
                : equals({
                    'kept-book': {'2026-9-17': 30.0},
                  }),
          );
          final preferences = await SharedPreferences.getInstance();
          expect(preferences.containsKey('hist'), isFalse);
          expect(preferences.containsKey('read_time_map'), !clearAll);
          expect(preferences.getString(themeModeKey), 'dark');
        },
      );
    }

    for (final scenario in [
      (clearAll: false, failedKey: 'hist'),
      (clearAll: true, failedKey: 'hist'),
      (clearAll: true, failedKey: 'read_time_map'),
    ]) {
      for (final throws in [false, true]) {
        test(
          '${scenario.clearAll ? 'all data' : 'history'} retries a '
          '${scenario.failedKey} removal that ${throws ? 'throws' : 'returns false'}',
          () async {
            final original = SharedPreferencesStorePlatform.instance;
            final fake = _FailingRemovalStore(
              await original.getAll(),
              failedKey: 'flutter.${scenario.failedKey}',
              throws: throws,
            );
            SharedPreferencesStorePlatform.instance = fake;
            addTearDown(() {
              SharedPreferences.resetStatic();
              SharedPreferencesStorePlatform.instance = original;
            });
            Future<void> clear() => scenario.clearAll
                ? store.clearReadingData()
                : store.clearHistory();

            await expectLater(
              clear(),
              throwsA(throws ? isA<PlatformException>() : isA<StateError>()),
            );
            expect(await store.historyEntry('kept-book'), isNotNull);
            expect(store.readTimeSnapshot()['kept-book'], {'2026-9-17': 30.0});
            final preferences = await SharedPreferences.getInstance();
            // SharedPreferences mutates its cache before its platform write.
            expect(preferences.containsKey(scenario.failedKey), isFalse);
            expect(
              (await fake.getAll()).containsKey(
                'flutter.${scenario.failedKey}',
              ),
              isTrue,
            );

            fake.fail = false;
            // Retry without reload: a missing in-memory key must not skip disk.
            await clear();
            expect(
              fake.removals.where(
                (key) => key == 'flutter.${scenario.failedKey}',
              ),
              hasLength(2),
            );
            await Hive.close();
            SharedPreferences.resetStatic();
            await store.init();
            expect(store.historySnapshot(), isEmpty);
            expect(
              store.readTimeSnapshot(),
              scenario.clearAll
                  ? isEmpty
                  : equals({
                      'kept-book': {'2026-9-17': 30.0},
                    }),
            );
            expect(
              (await SharedPreferences.getInstance()).getString(themeModeKey),
              'dark',
            );
          },
        );
      }
    }
  });

  group('paragraph identity across empty layout fragments', () {
    test(
      'old and unknown parser revisions retain content but require checking',
      () {
        for (final revision in <int?>[null, 0, 1]) {
          final cache =
              '\u001efqapp:chapter:2\n${jsonEncode({
                'version': 2,
                'illustrationsChecked': true,
                'paragraphIdsChecked': true,
                'paragraphParserRevision': ?revision,
                // Written before the reader read the spoken timeline.
                'timelineChecked': false,
                'legacyText': '标题\n已丢编号的正文\n已有编号',
                'blocks': [
                  {'type': 'text', 'text': '标题'},
                  {'type': 'text', 'text': '已丢编号的正文'},
                  {'type': 'text', 'text': '已有编号', 'idx': 8},
                  {'type': 'image', 'url': 'https://images.test/a'},
                ],
              })}';
          final content = ChapterContent.fromCacheText(cache);
          for (final value in [
            content,
            content.withoutLeadingTitle('标题'),
            ChapterContent.fromCacheText(content.toCacheText()),
          ]) {
            expect(value.paragraphIdsChecked, isFalse);
            expect(value.timelineChecked, isFalse);
            expect(value.images.single.url, 'https://images.test/a');
            final paragraphs = value.blocks.whereType<ChapterParagraph>();
            expect(paragraphs.last.paraIndex, 8);
            expect(paragraphs.any((p) => p.text == '已丢编号的正文'), isTrue);
          }
        }
      },
    );

    test(
      'fresh markup without ids stays checked across transforms and cache',
      () {
        final content = parseChapterContent('<h1>标题</h1><p>没有编号</p>');
        for (final value in [
          content,
          content.withoutLeadingTitle('标题'),
          ChapterContent.fromCacheText(content.toCacheText()),
        ]) {
          expect(value.paragraphIdsChecked, isTrue);
          expect(
            value.blocks.whereType<ChapterParagraph>().every(
              (p) => p.paraIndex == null,
            ),
            isTrue,
          );
        }
      },
    );

    for (final leading in [
      '<br>',
      ' \n<br><br>',
      '<img src="https://images.test/a">',
      '<img src="invalid:scheme" alt="图片说明">',
    ]) {
      test('leading $leading preserves the first body paragraph id', () {
        final content = parseChapterContent(
          '<p idx="7">$leading正文</p><p idx="8">下一段</p>',
        );
        for (final value in [
          content,
          ChapterContent.fromCacheText(content.toCacheText()),
        ]) {
          final body = value.blocks.whereType<ChapterParagraph>().where(
            (paragraph) => !paragraph.isImageCaption,
          );
          expect(body.map((paragraph) => paragraph.text), ['正文', '下一段']);
          expect(body.map((paragraph) => paragraph.paraIndex), [7, 8]);
          expect(
            value.blocks
                .whereType<ChapterParagraph>()
                .where((paragraph) => paragraph.isImageCaption)
                .every((paragraph) => paragraph.paraIndex == null),
            isTrue,
          );
        }
      });
    }

    test('only the first body fragment consumes a paragraph id', () {
      final content = parseChapterContent(
        '<p idx="7">前文<br>中段<img src="https://images.test/a">后文</p>',
      );
      expect(
        content.blocks.whereType<ChapterParagraph>().map((p) => p.paraIndex),
        [7, null, null],
      );
    });

    test(
      'empty and image-only paragraphs cannot leak an id into later text',
      () {
        final content = parseChapterContent(
          '<p idx="7"> <br><img src="https://images.test/a"></p>'
          '段外文字<p>无编号</p><p idx="8"><br></p>末尾文字',
        );
        final paragraphs = content.blocks.whereType<ChapterParagraph>();
        expect(paragraphs.map((p) => p.text), ['段外文字', '无编号', '末尾文字']);
        expect(paragraphs.map((p) => p.paraIndex), [null, null, null]);
      },
    );
  });
}

class _FailingRemovalStore extends InMemorySharedPreferencesStore {
  _FailingRemovalStore(
    super.data, {
    required this.failedKey,
    required this.throws,
  }) : super.withData();

  final String failedKey;
  final bool throws;
  bool fail = true;
  final removals = <String>[];

  @override
  Future<bool> remove(String key) async {
    removals.add(key);
    if (fail && key == failedKey) {
      if (throws) {
        throw PlatformException(code: 'write-failed', message: 'cannot remove');
      }
      return false;
    }
    return super.remove(key);
  }
}
