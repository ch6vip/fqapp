import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/webdav_sync_document.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:fqapp/services/webdav_sync_service.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

const config = WebDavConfig(
  directory: 'https://dav.example.com/books/',
  username: 'reader',
  password: 'private-password',
  enabled: false,
);

MediaItem item(String id) => MediaItem(
  id: id,
  kind: 'book',
  title: id,
  cover: '',
  author: '',
  badge: '',
  ep: '',
);
LibraryBackup backup({
  List<ShelfRecord> shelf = const [],
  List<Map<String, dynamic>> history = const [],
}) => LibraryBackup.capture(shelf: shelf, history: history, watched: {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reader exposes the exact mist blue background and persists it',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        ReaderThemePreset.mistBlue.backgroundColor,
        const Color(0xFFD8E4F0),
      );
      expect(
        ReaderThemePreset.mistBlue.theme(ThemeData()).scaffoldBackgroundColor,
        const Color(0xFFD8E4F0),
      );
      final prefs = const ReaderPreferences(
        themePreset: ReaderThemePreset.mistBlue,
      );
      await prefs.save();
      expect(
        (await ReaderPreferences.load()).themePreset,
        ReaderThemePreset.mistBlue,
      );
      expect(ReaderThemePreset.light.backgroundColor, const Color(0xFFFAF9F6));
    },
  );

  test(
    'merge keeps the newest position even when the reader went backwards',
    () {
      final older = WebDavSyncDocument(
        backup(
          history: [
            {'id': 'book1', 'kind': 'book', 'chapterId': 'c9', 'time': 100},
          ],
        ),
      );
      final newer = WebDavSyncDocument(
        backup(
          history: [
            {'id': 'book1', 'kind': 'book', 'chapterId': 'c2', 'time': 200},
            {'id': 'book2', 'kind': 'audio', 'position': 38.5, 'time': 201},
          ],
        ),
      );
      for (final merged in [older.merge(newer), newer.merge(older)]) {
        final decoded = WebDavSyncDocument.decode(merged.encode());
        expect(
          decoded.backup.history.firstWhere(
            (e) => e['id'] == 'book1',
          )['chapterId'],
          'c2',
        );
        expect(decoded.backup.history, hasLength(2));
      }
    },
  );

  test('merge retains AI backup data from either device', () {
    final local = WebDavSyncDocument(
      LibraryBackup.capture(
        shelf: const [],
        history: const [],
        watched: const {},
        aiData: 'local-ai',
      ),
    );
    final remote = WebDavSyncDocument(
      LibraryBackup.capture(
        shelf: const [],
        history: const [],
        watched: const {},
        aiData: 'remote-ai',
      ),
    );

    expect(local.merge(remote).backup.aiData, 'local-ai');
    expect(remote.merge(local).backup.aiData, 'remote-ai');
  });

  test(
    'shelf tombstone defeats an offline copy but permits a later re-add',
    () {
      final old = WebDavSyncDocument(
        backup(
          shelf: [
            ShelfRecord(
              item: item('one'),
              addedAt: DateTime.fromMillisecondsSinceEpoch(100),
            ),
          ],
        ),
      );
      final removed = WebDavSyncDocument(backup(), {'shelf_v1:book:one': 200});
      expect(old.merge(removed).backup.shelf, isEmpty);
      expect(removed.merge(old).backup.shelf, isEmpty);
      final readded = WebDavSyncDocument(
        backup(
          shelf: [
            ShelfRecord(
              item: item('one'),
              addedAt: DateTime.fromMillisecondsSinceEpoch(300),
            ),
          ],
        ),
      );
      expect(removed.merge(readded).backup.shelf.single.item.id, 'one');
    },
  );

  test('rejects unsupported documents and malformed tombstones', () {
    expect(
      () => WebDavSyncDocument.decode(Uint8List.fromList(utf8.encode('{}'))),
      throwsFormatException,
    );
    final raw =
        jsonDecode(utf8.decode(WebDavSyncDocument(backup()).encode())) as Map;
    raw['removedShelf'] = {'unexpected-key': -1};
    expect(
      () => WebDavSyncDocument.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(raw))),
      ),
      throwsFormatException,
    );
  });

  test(
    'uses conditional writes, Basic auth and never follows redirects',
    () async {
      final requests = <http.Request>[];
      final client = WebDavClient(
        config,
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response('{}', 200, headers: {'etag': '"v1"'});
          }
          return http.Response(
            '',
            request.headers['if-match'] == '"v1"' ? 412 : 201,
          );
        }),
      );
      addTearDown(client.close);
      expect((await client.read()).etag, '"v1"');
      expect(await client.write(Uint8List(0), '"v1"'), isFalse);
      expect(await client.write(Uint8List(0), null), isTrue);
      expect(requests.last.headers['if-none-match'], '*');
      expect(requests.first.followRedirects, isFalse);
      expect(
        requests.first.url.toString(),
        'https://dav.example.com/books/fqapp-sync.json',
      );
      expect(
        requests.first.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('reader:private-password'))}',
      );
    },
  );

  test(
    'authentication, weak ETags, redirects and oversized files fail safely',
    () async {
      for (final response in [
        http.Response('', 401),
        http.Response('', 302),
        http.Response('{}', 200, headers: {'etag': 'W/"v1"'}),
        http.Response('{}', 200),
      ]) {
        final client = WebDavClient(
          config,
          client: MockClient((_) async => response),
        );
        await expectLater(client.read(), throwsA(isA<WebDavException>()));
        client.close();
      }
      final client = WebDavClient(
        config,
        client: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(
        client.write(Uint8List(WebDavClient.maxBytes + 1), null),
        throwsA(isA<WebDavException>()),
      );
      client.close();
      expect(
        () => const WebDavConfig(
          directory: 'http://dav.example.com/',
          username: '',
          password: '',
          enabled: false,
        ).fileUri,
        throwsA(isA<WebDavException>()),
      );
    },
  );

  group('sync against a conditional WebDAV server', () {
    late Directory directory;
    late WebDavSyncService service;
    Uint8List? remote;
    var version = 0;
    var conflict = false;
    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('fqapp-webdav-');
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      remote = null;
      version = 0;
      conflict = false;
      service = WebDavSyncService(
        createClient: (settings) => WebDavClient(
          settings,
          client: MockClient((request) async {
            if (request.method == 'GET') {
              return remote == null
                  ? http.Response('', 404)
                  : http.Response.bytes(
                      remote!,
                      200,
                      headers: {'etag': '"$version"'},
                    );
            }
            if (conflict) {
              conflict = false;
              remote = WebDavSyncDocument(
                backup(
                  history: [
                    {'id': 'second-device', 'kind': 'book', 'time': 500},
                  ],
                ),
              ).encode();
              version++;
              return http.Response('', 412);
            }
            if ((remote == null && request.headers['if-none-match'] != '*') ||
                (remote != null &&
                    request.headers['if-match'] != '"$version"')) {
              return http.Response('', 412);
            }
            remote = request.bodyBytes;
            version++;
            return http.Response('', 204);
          }),
        ),
      );
      await service.configure(config);
    });
    tearDown(() async {
      await service.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test(
      'pushes local state, retries a competing writer and imports progress',
      () async {
        await ShelfStore.instance.add(item('local'));
        await LibraryStore.instance.addHistory({
          'id': 'progress',
          'kind': 'book',
          'chapterId': 'c1',
          'time': 100,
        });
        conflict = true;
        await service.sync();
        var cloud = WebDavSyncDocument.decode(remote!);
        expect(cloud.backup.shelf.single.item.id, 'local');
        expect(
          cloud.backup.history.map((e) => e['id']),
          containsAll(['progress', 'second-device']),
        );
        expect(
          (await LibraryStore.instance.historyEntry('second-device'))?['time'],
          500,
        );
        remote = cloud
            .merge(
              WebDavSyncDocument(
                backup(
                  history: [
                    {
                      'id': 'progress',
                      'kind': 'book',
                      'chapterId': 'c2',
                      'time': 200,
                    },
                  ],
                ),
              ),
            )
            .encode();
        version++;
        await service.sync();
        expect(
          (await LibraryStore.instance.historyEntry('progress'))?['chapterId'],
          'c2',
        );
        await ShelfStore.instance.removeKeys(['shelf_v1:book:local']);
        await service.sync();
        cloud = WebDavSyncDocument.decode(remote!);
        expect(cloud.backup.shelf, isEmpty);
        expect(cloud.removedShelf, contains('shelf_v1:book:local'));
      },
    );

    test(
      'automatic mode pushes changes and pulls on returning to the app',
      () async {
        await service.configure(
          WebDavConfig(
            directory: config.directory,
            username: config.username,
            password: config.password,
            enabled: true,
          ),
        );
        await service.sync();
        await ShelfStore.instance.add(item('automatic'));
        await Future<void>.delayed(const Duration(seconds: 4));
        expect(
          WebDavSyncDocument.decode(remote!).backup.shelf.single.item.id,
          'automatic',
        );
        remote = WebDavSyncDocument.decode(remote!)
            .merge(
              WebDavSyncDocument(
                backup(
                  history: [
                    {'id': 'remote-resume', 'kind': 'book', 'time': 600},
                  ],
                ),
              ),
            )
            .encode();
        version++;
        service.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await service.sync();
        expect(
          await LibraryStore.instance.historyEntry('remote-resume'),
          isNotNull,
        );
      },
    );

    test(
      'invalid remote never replaces the cloud file or local shelf',
      () async {
        await ShelfStore.instance.add(item('keep'));
        remote = Uint8List.fromList(utf8.encode('not json'));
        await expectLater(service.sync(), throwsFormatException);
        expect(ShelfStore.instance.contains('book', 'keep'), isTrue);
        expect(utf8.decode(remote!), 'not json');
        expect(service.busy.value, isFalse);
      },
    );
  });
}
