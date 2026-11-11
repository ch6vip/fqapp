import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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

import 'support/secure_key_storage_mock.dart';
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

  test('creates missing WebDAV collections before retrying upload', () async {
    final methods = <String>[];
    var puts = 0;
    final client = WebDavClient(
      config,
      client: MockClient((request) async {
        methods.add('${request.method} ${request.url.path}');
        if (request.method == 'MKCOL') return http.Response('', 201);
        return http.Response('', ++puts == 1 ? 409 : 201);
      }),
    );
    expect(await client.write(Uint8List(0), null), isTrue);
    expect(methods, [
      'PUT /books/fqapp-sync.json',
      'MKCOL /books/',
      'PUT /books/fqapp-sync.json',
    ]);
    client.close();
  });

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
      for (final request in requests) {
        expect(request.headers['accept-encoding'], 'identity');
      }
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
    var offline = false;
    setUp(() async {
      mockSecureKeyStorage();
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('fqapp-webdav-');
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      remote = null;
      version = 0;
      conflict = false;
      offline = false;
      service = WebDavSyncService(
        createClient: (settings) => WebDavClient(
          settings,
          client: MockClient((request) async {
            if (offline) throw http.ClientException('offline');
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

    test('a fresh device imports the online shelf from the server', () async {
      remote = WebDavSyncDocument(
        backup(
          shelf: [
            ShelfRecord(
              item: item('from-other-device'),
              addedAt: DateTime(2025),
            ),
          ],
        ),
      ).encode();
      version++;
      expect(ShelfStore.instance.records(), isEmpty);
      await service.sync();
      expect(ShelfStore.instance.records().single.item.id, 'from-other-device');
      expect(service.status.value, contains('书架 1 本'));
    });

    test(
      'cloud forcibly replaces local shelf and newer progress without PUT',
      () async {
        await ShelfStore.instance.add(item('local-only'));
        await LibraryStore.instance.addHistory({
          'id': 'progress',
          'kind': 'book',
          'chapterId': 'local-new',
          'time': 900,
        });
        await LibraryStore.instance.addHistory({
          'id': 'local-only',
          'kind': 'book',
          'time': 900,
        });
        remote = WebDavSyncDocument(
          backup(
            shelf: [
              ShelfRecord(item: item('cloud-only'), addedAt: DateTime(2025)),
            ],
            history: [
              {
                'id': 'progress',
                'kind': 'book',
                'chapterId': 'cloud-old',
                'time': 100,
              },
            ],
          ),
        ).encode();
        version++;
        final before = remote!.toList();
        await service.sync();
        expect(ShelfStore.instance.records().single.item.id, 'cloud-only');
        expect(
          (await LibraryStore.instance.historyEntry('progress'))?['chapterId'],
          'cloud-old',
        );
        expect(await LibraryStore.instance.historyEntry('local-only'), isNull);
        expect(remote, orderedEquals(before));
        expect(version, 1);
      },
    );

    test(
      'only a missing cloud file is seeded; a competing creator wins',
      () async {
        await ShelfStore.instance.add(item('local-only'));
        conflict = true;
        await service.sync();
        expect(ShelfStore.instance.records(), isEmpty);
        expect(
          await LibraryStore.instance.historyEntry('second-device'),
          isNotNull,
        );
        expect(WebDavSyncDocument.decode(remote!).backup.shelf, isEmpty);
      },
    );

    test(
      'automatic mode restores cloud after local changes and on resume',
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
        expect(ShelfStore.instance.records(), isEmpty);
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
      'single and batch history deletions reach cloud and do not return',
      () async {
        remote = WebDavSyncDocument(
          backup(
            history: [
              {'id': 'one', 'kind': 'book', 'time': 1},
              {'id': 'two', 'kind': 'audio', 'time': 2},
              {'id': 'keep', 'kind': 'book', 'time': 3},
            ],
          ),
        ).encode();
        version++;
        await service.sync();
        await LibraryStore.instance.removeHistoryEntry('one', 'book');
        await LibraryStore.instance.removeHistoryEntries([
          (contentId: 'two', kind: 'audio'),
        ]);
        await service.sync();
        expect(
          WebDavSyncDocument.decode(remote!).backup.history.single['id'],
          'keep',
        );
        await service.sync();
        expect(await LibraryStore.instance.historyEntry('one'), isNull);
        expect(await LibraryStore.instance.historyEntry('audio:two'), isNull);
      },
    );

    test(
      'offline clear is retained and empty history is uploaded on retry',
      () async {
        remote = WebDavSyncDocument(
          backup(
            history: [
              {'id': 'one', 'kind': 'book', 'time': 1},
            ],
          ),
        ).encode();
        version++;
        await service.sync();
        await LibraryStore.instance.clearHistory();
        offline = true;
        await expectLater(service.sync(), throwsA(isA<WebDavException>()));
        offline = false;
        await service.sync();
        expect(WebDavSyncDocument.decode(remote!).backup.history, isEmpty);
        expect(await LibraryStore.instance.historyEntry('one'), isNull);
      },
    );

    test('pending offline deletions survive service restart', () async {
      remote = WebDavSyncDocument(
        backup(
          history: [
            {'id': 'one', 'kind': 'book', 'time': 1},
          ],
        ),
      ).encode();
      version++;
      await service.sync();
      await LibraryStore.instance.clearHistory();
      offline = true;
      await expectLater(service.sync(), throwsA(isA<WebDavException>()));
      await service.dispose();
      offline = false;
      service = WebDavSyncService(
        createClient: (settings) => WebDavClient(
          settings,
          client: MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response.bytes(
                remote!,
                200,
                headers: {'etag': '"$version"'},
              );
            }
            expect(request.headers['if-match'], '"$version"');
            remote = request.bodyBytes;
            version++;
            return http.Response('', 204);
          }),
        ),
      );
      await service.configure(config);
      await service.sync();
      expect(WebDavSyncDocument.decode(remote!).backup.history, isEmpty);
      expect(await LibraryStore.instance.historyEntry('one'), isNull);
    });

    test(
      'shelf removal propagates, including source-qualified identities',
      () async {
        final book = MediaItem(
          id: 'remote',
          kind: 'book',
          title: '书旗',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          source: 'shuqi',
        );
        remote = WebDavSyncDocument(
          backup(
            shelf: [ShelfRecord(item: book, addedAt: DateTime(2025))],
          ),
        ).encode();
        version++;
        await service.sync();
        await ShelfStore.instance.removeKeys([ShelfStore.keyOf(book)]);
        await service.sync();
        expect(WebDavSyncDocument.decode(remote!).backup.shelf, isEmpty);
        expect(ShelfStore.instance.records(), isEmpty);
      },
    );

    test(
      'conditional conflict retains pending deletion and remote additions',
      () async {
        remote = WebDavSyncDocument(
          backup(
            history: [
              {'id': 'one', 'kind': 'book', 'time': 1},
            ],
          ),
        ).encode();
        version++;
        await service.sync();
        await LibraryStore.instance.removeHistoryEntry('one', 'book');
        conflict = true;
        await service.sync();
        final history = WebDavSyncDocument.decode(remote!).backup.history;
        expect(history.single['id'], 'second-device');
        expect(await LibraryStore.instance.historyEntry('one'), isNull);
      },
    );

    test(
      'forgetting watched episodes propagates without deleting unrelated history',
      () async {
        remote = WebDavSyncDocument(
          LibraryBackup.capture(
            shelf: [],
            history: [
              {'id': 'show', 'kind': 'video', 'time': 1},
            ],
            watched: {
              'show': {'ep1': 1},
            },
          ),
        ).encode();
        version++;
        await service.sync();
        await LibraryStore.instance.forgetWatchedEpisodes('show');
        await service.sync();
        expect(WebDavSyncDocument.decode(remote!).backup.watched, isEmpty);
        expect(await LibraryStore.instance.historyEntry('show'), isNotNull);
      },
    );

    test(
      'a vanished established cloud file is not recreated from stale local state',
      () async {
        remote = WebDavSyncDocument(
          backup(
            history: [
              {'id': 'one', 'kind': 'book', 'time': 1},
            ],
          ),
        ).encode();
        version++;
        await service.sync();
        remote = null;
        await expectLater(service.sync(), throwsA(isA<WebDavException>()));
        expect(remote, isNull);
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
