import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';

import 'audio_download_store.dart';
import 'drama_download_store.dart';
import 'encrypted_hive.dart';
import 'secure_key_provider.dart';

enum DownloadKind { audio, drama }

enum DownloadResumeStage { receiving, ready, promoted, discarding }

class DownloadKey {
  DownloadKey(this.kind, this.itemId, [this.toneId = '']) {
    if (!_safe.hasMatch(itemId) ||
        (kind == DownloadKind.audio
            ? !_safe.hasMatch(toneId)
            : toneId.isNotEmpty)) {
      throw ArgumentError('Invalid download key');
    }
  }

  static final _safe = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  final DownloadKind kind;
  final String itemId;
  final String toneId;

  String get storageKey => '${kind.name}:$itemId|$toneId';
  String get fileName =>
      kind == DownloadKind.audio ? '${itemId}__$toneId.m4a' : '$itemId.mp4';
}

class DownloadIdentity {
  const DownloadIdentity({
    required this.containerId,
    required this.keyHex,
    required this.rendition,
    required this.height,
    required this.total,
    required this.requestedDigest,
    required this.effectiveDigest,
    this.strongETag,
  });

  final String containerId;
  final String keyHex;
  final String rendition;
  final int height;
  final int total;
  final String? requestedDigest;
  final String? effectiveDigest;
  final String? strongETag;

  static String uriDigest(Uri uri) =>
      sha256.convert(utf8.encode('$uri')).toString();

  static String? strongTag(String? value) {
    if (value == null ||
        !RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value)) {
      return null;
    }
    return value;
  }

  Map<String, Object?> toMap() => {
    'containerId': containerId,
    'keyHex': keyHex,
    'rendition': rendition,
    'height': height,
    'total': total,
    'requestedDigest': requestedDigest,
    'effectiveDigest': effectiveDigest,
    'strongETag': strongETag,
  };

  static DownloadIdentity? fromMap(dynamic raw, {bool discarding = false}) {
    if (raw is! Map ||
        raw['containerId'] is! String ||
        (raw['containerId'] as String).isEmpty ||
        raw['keyHex'] is! String ||
        (raw['keyHex'] as String).length > 128 ||
        raw['rendition'] is! String ||
        raw['height'] is! int ||
        (raw['height'] as int) < 0 ||
        raw['total'] is! int ||
        (raw['total'] as int) <= 0) {
      return null;
    }
    final digest = RegExp(r'^[0-9a-f]{64}$');
    bool validDigest(dynamic value) =>
        value is String ? digest.hasMatch(value) : discarding && value == null;
    if (!validDigest(raw['requestedDigest']) ||
        !validDigest(raw['effectiveDigest']) ||
        (raw['strongETag'] != null &&
            (raw['strongETag'] is! String ||
                strongTag(raw['strongETag'] as String) == null))) {
      return null;
    }
    return DownloadIdentity(
      containerId: raw['containerId'] as String,
      keyHex: raw['keyHex'] as String,
      rendition: raw['rendition'] as String,
      height: raw['height'] as int,
      total: raw['total'] as int,
      requestedDigest: raw['requestedDigest'] as String?,
      effectiveDigest: raw['effectiveDigest'] as String?,
      strongETag: raw['strongETag'] as String?,
    );
  }
}

// No persisted file path: recovery always rebuilds it from the current root/key.
class DownloadRecord {
  const DownloadRecord({
    required this.title,
    required this.index,
    required this.cachedAt,
    this.durationMs,
    this.auto = false,
  });

  final String title;
  final int index;
  final int cachedAt;
  final int? durationMs;
  final bool auto;

  Map<String, Object?> toMap() => {
    'title': title,
    'index': index,
    'cachedAt': cachedAt,
    'durationMs': durationMs,
    'auto': auto,
  };

  static DownloadRecord? fromMap(dynamic raw) {
    if (raw is! Map ||
        raw['title'] is! String ||
        raw['index'] is! int ||
        (raw['index'] as int) < 0 ||
        raw['cachedAt'] is! int ||
        (raw['cachedAt'] as int) <= 0 ||
        raw['auto'] is! bool ||
        (raw['durationMs'] != null &&
            (raw['durationMs'] is! int || (raw['durationMs'] as int) < 0))) {
      return null;
    }
    return DownloadRecord(
      title: raw['title'] as String,
      index: raw['index'] as int,
      cachedAt: raw['cachedAt'] as int,
      durationMs: raw['durationMs'] as int?,
      auto: raw['auto'] as bool,
    );
  }
}

class DownloadResumeEntry {
  const DownloadResumeEntry(
    this.key,
    this.stage, {
    this.identity,
    this.record,
    this.finalOwned = false,
  });

  final DownloadKey key;
  final DownloadResumeStage stage;
  final DownloadIdentity? identity;
  final DownloadRecord? record;
  final bool finalOwned;

  DownloadResumeEntry at(
    DownloadResumeStage stage, {
    DownloadRecord? record,
    bool? finalOwned,
  }) => DownloadResumeEntry(
    key,
    stage,
    identity: identity,
    record: record ?? this.record,
    finalOwned:
        finalOwned ??
        (stage == DownloadResumeStage.ready ||
            stage == DownloadResumeStage.promoted ||
            this.finalOwned),
  );

  Map<String, Object?> toMap() => {
    'version': 1,
    'kind': key.kind.name,
    'itemId': key.itemId,
    'toneId': key.toneId,
    'stage': stage.name,
    'identity': identity?.toMap(),
    'record': record?.toMap(),
    'finalOwned': finalOwned,
  };

  static DownloadResumeEntry? fromMap(DownloadKey key, dynamic raw) {
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['kind'] != key.kind.name ||
        raw['itemId'] != key.itemId ||
        raw['toneId'] != key.toneId) {
      return null;
    }
    DownloadResumeStage? stage;
    for (final candidate in DownloadResumeStage.values) {
      if (candidate.name == raw['stage']) stage = candidate;
    }
    if (stage == null || raw['finalOwned'] is! bool) return null;
    final identity = DownloadIdentity.fromMap(
      raw['identity'],
      discarding: stage == DownloadResumeStage.discarding,
    );
    final record = DownloadRecord.fromMap(raw['record']);
    if ((raw['identity'] != null && identity == null) ||
        (raw['record'] != null && record == null) ||
        (stage != DownloadResumeStage.discarding && identity == null) ||
        ((stage == DownloadResumeStage.ready ||
                stage == DownloadResumeStage.promoted) &&
            record == null) ||
        (record != null && identity == null) ||
        (raw['finalOwned'] == true && (identity == null || record == null))) {
      return null;
    }
    return DownloadResumeEntry(
      key,
      stage,
      identity: identity,
      record: record,
      finalOwned: raw['finalOwned'] as bool,
    );
  }

  CachedAudioChapter audioChapter(String finalPath) => CachedAudioChapter(
    bookId: identity!.containerId,
    itemId: key.itemId,
    toneId: key.toneId,
    title: record!.title,
    index: record!.index,
    keyHex: identity!.keyHex,
    bytes: identity!.total,
    filePath: finalPath,
    cachedAt: record!.cachedAt,
    durationMs: record!.durationMs,
  );

  CachedEpisode dramaEpisode(String finalPath) => CachedEpisode(
    seriesId: identity!.containerId,
    itemId: key.itemId,
    title: record!.title,
    index: record!.index,
    keyHex: identity!.keyHex,
    height: identity!.height,
    variantName: identity!.rendition,
    bytes: identity!.total,
    filePath: finalPath,
    cachedAt: record!.cachedAt,
    auto: record!.auto,
  );

  bool matchesAudio(CachedAudioChapter row, String path) {
    if (identity == null || record == null) return false;
    final expected = audioChapter(path);
    return row.keyHex == expected.keyHex &&
        _sameMap(row.toMap(), expected.toMap());
  }

  bool matchesDrama(CachedEpisode row, String path) {
    if (identity == null || record == null) return false;
    final expected = dramaEpisode(path);
    return row.keyHex == expected.keyHex &&
        _sameMap(row.toMap(), expected.toMap());
  }

  static bool _sameMap(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a.length == b.length && a.keys.every((key) => a[key] == b[key]);
}

class DownloadResumeStore {
  DownloadResumeStore({HiveInterface? hive, this.keys}) : _hive = hive ?? Hive;

  /// In-memory journal for callers that provide a non-Hive download store.
  ///
  /// Production uses [instance] so a process restart can recover a `.part`
  /// file. Tests and other ephemeral stores do not have an encrypted Hive box,
  /// so they must not fall through to the global journal (which would try to
  /// open it without the store's key provider).
  DownloadResumeStore.memory() : _hive = null, keys = null;

  static final instance = DownloadResumeStore();
  static const _name = 'download_resume_v1';
  final HiveInterface? _hive;
  final SecureKeyProvider? keys;
  final Map<String, DownloadResumeEntry> _memoryEntries = {};
  Future<void> _writes = Future<void>.value();

  Future<T> _serializeMemory<T>(Future<T> Function() action) {
    final operation = _writes.then((_) => action());
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<T> _serialize<T>(Future<T> Function(Box<dynamic>) action) {
    final operation = _writes.then((_) async {
      final box = await EncryptedHive.openBox<dynamic>(
        _hive!,
        _name,
        keys: keys,
        requireEncryption: true,
      );
      return action(box);
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<DownloadResumeEntry?> read(DownloadKey key) {
    if (_hive == null) {
      return _serializeMemory(() async => _memoryEntries[key.storageKey]);
    }
    return _serialize(
      (box) async => DownloadResumeEntry.fromMap(key, box.get(key.storageKey)),
    );
  }

  Future<void> write(DownloadResumeEntry entry) {
    final raw = entry.toMap();
    if (DownloadResumeEntry.fromMap(entry.key, raw) == null) {
      return Future<void>.error(StateError('Invalid resume identity'));
    }
    if (_hive == null) {
      return _serializeMemory(() async {
        _memoryEntries[entry.key.storageKey] = entry;
      });
    }
    return _serialize((box) async {
      await box.put(entry.key.storageKey, raw);
      await box.flush();
    });
  }

  Future<void> remove(DownloadKey key) {
    if (_hive == null) {
      return _serializeMemory(() async {
        _memoryEntries.remove(key.storageKey);
      });
    }
    return _serialize((box) async {
      await box.delete(key.storageKey);
      await box.flush();
    });
  }
}

class DownloadFiles {
  DownloadFiles._(this.root, this.part, this.finalFile);

  final String root;
  final File part;
  final File finalFile;

  static Future<DownloadFiles> inDirectory(
    Directory directory,
    DownloadKey key,
  ) async {
    final root = await directory.resolveSymbolicLinks();
    final finalFile = File('$root${Platform.pathSeparator}${key.fileName}');
    return DownloadFiles._(root, File('${finalFile.path}.part'), finalFile);
  }

  Future<int?> length(File file) async {
    if (!_samePath(await Directory(root).resolveSymbolicLinks(), root)) {
      throw FileSystemException('Download root ownership conflict', root);
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file ||
        !_samePath(await file.resolveSymbolicLinks(), file.path)) {
      throw FileSystemException('Download path ownership conflict', file.path);
    }
    return file.length();
  }

  static bool _samePath(String a, String b) =>
      Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;

  Future<void> promote(int total) async {
    if (await length(finalFile) != null) {
      throw FileSystemException('Final file already exists', finalFile.path);
    }
    if (await length(part) != total) {
      throw FileSystemException('Part file length conflict', part.path);
    }
    await part.rename(finalFile.path);
  }

  Future<void> delete(File file) async {
    if (await length(file) != null) await file.delete();
    if (await length(file) != null) {
      throw FileSystemException('Download cleanup incomplete', file.path);
    }
  }
}
