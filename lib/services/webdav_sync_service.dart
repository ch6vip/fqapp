import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';

import '../models/webdav_sync_document.dart';
import 'encrypted_hive.dart';
import 'library_backup_service.dart';
import 'library_store.dart';
import 'shelf_store.dart';
import 'webdav_client.dart';

class WebDavSyncService with WidgetsBindingObserver {
  WebDavSyncService({WebDavClient Function(WebDavConfig)? createClient})
    : _createClient = createClient ?? WebDavClient.new;
  static final instance = WebDavSyncService();
  final WebDavClient Function(WebDavConfig) _createClient;
  static const _storage = FlutterSecureStorage();
  static const _configKey = 'fqapp.webdav.config.v1';
  final status = ValueNotifier<String>('尚未配置');
  final busy = ValueNotifier<bool>(false);
  WebDavConfig? config;
  Timer? _debounce;
  Timer? _poll;
  bool _attached = false;
  bool _applying = false;
  int _generation = 0;
  Future<void>? _running;
  Box<dynamic>? _state;

  Future<void> init() async {
    final saved = await _storage.read(key: _configKey);
    if (saved != null) {
      config = WebDavConfig.fromJson(jsonDecode(saved) as Map<String, dynamic>);
    }
    await _activate();
  }

  Future<void> configure(WebDavConfig next) async {
    next.fileUri; // Validate before saving either credentials or enablement.
    if (next.username.contains(':')) {
      throw const WebDavException('WebDAV 用户名不能包含冒号');
    }
    // Fail closed: passwords are never put into preferences or backup files.
    await _storage.write(key: _configKey, value: jsonEncode(next.toJson()));
    _generation++;
    _detach();
    config = next;
    await _activate();
  }

  Future<void> _activate() async {
    if (config?.enabled != true) {
      status.value = config == null ? '尚未配置' : '自动同步已关闭';
      return;
    }
    _state ??= await EncryptedHive.openBox<dynamic>(
      Hive,
      'webdav_sync_state',
      requireEncryption: true,
    );
    if (!_attached) {
      _attached = true;
      ShelfStore.instance.listenable.addListener(_changed);
      LibraryStore.instance.historyListenable.addListener(_changed);
      WidgetsBinding.instance.addObserver(this);
    }
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(minutes: 2), (_) => _automatic());
    _automatic();
  }

  void _detach() {
    _debounce?.cancel();
    _poll?.cancel();
    if (!_attached) return;
    ShelfStore.instance.listenable.removeListener(_changed);
    LibraryStore.instance.historyListenable.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    _attached = false;
  }

  void _changed() {
    if (_applying || config?.enabled != true) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), _automatic);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _automatic();
    if (state == AppLifecycleState.paused) _automatic();
  }

  void _automatic() {
    if (config?.enabled != true) return;
    unawaited(sync().catchError((Object _) {}));
  }

  Future<void> sync() {
    if (_running case final running?) return running;
    final operation = _sync();
    _running = operation;
    unawaited(
      operation.then(
        (_) {
          _running = null;
        },
        onError: (Object _, StackTrace _) {
          _running = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _sync() async {
    final settings = config;
    if (settings == null) throw const WebDavException('请先保存 WebDAV 设置');
    final generation = _generation;
    bool current() => generation == _generation;
    busy.value = true;
    status.value = '正在同步…';
    final client = _createClient(settings);
    try {
      _state ??= await EncryptedHive.openBox<dynamic>(
        Hive,
        'webdav_sync_state',
        requireEncryption: true,
      );
      final scope = sha256
          .convert(utf8.encode('${settings.fileUri}\n${settings.username}'))
          .toString();
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!current()) return;
        final remote = await client.read();
        if (!current()) return;
        // Only an absent cloud file may be seeded from this device.
        if (remote.bytes == null) {
          final local = await LibraryBackupService().capture();
          if (!current()) return;
          if (!await client.write(WebDavSyncDocument(local).encode(), null)) {
            continue;
          }
          if (current()) status.value = '已建立云端备份 · 书架 ${local.shelf.length} 本';
          return;
        }
        final document = WebDavSyncDocument.decode(remote.bytes!);
        final incoming = document.backup;
        final prior = _state!.get(scope);
        final previous = prior is Map ? prior : const {};
        final aiHash = _aiFingerprint(incoming.aiData);
        if (incoming.aiData != null && aiHash != previous['aiHash']) {
          await LibraryBackupService().restoreAi(incoming);
          if (!current()) return;
        }
        _applying = true;
        try {
          await ShelfStore.instance.replaceSyncedShelf(incoming.shelf);
          await LibraryStore.instance.replaceSyncedHistory(
            history: incoming.history,
            watched: incoming.watched,
          );
          await _state!.put(scope, {'aiHash': aiHash});
        } finally {
          _applying = false;
        }
        if (current()) {
          final stamp = DateTime.now().toLocal().toString().split('.').first;
          status.value = '云端覆盖完成 · 书架 ${incoming.shelf.length} 本 · $stamp';
        }
        return;
      }
      throw const WebDavException('其他设备正在更新，请稍后重试');
    } catch (error) {
      if (current()) {
        status.value = switch (error) {
          WebDavException() => error.message,
          FormatException() => '云端同步文件无效，未导入本机',
          _ => '同步失败，请检查网络、WebDAV 设置和安全存储后重试',
        };
      }
      rethrow;
    } finally {
      client.close();
      busy.value = false;
    }
  }

  static String? _aiFingerprint(String? encoded) {
    if (encoded == null) return null;
    try {
      final payload =
          jsonDecode(
                utf8.decode(GZipDecoder().decodeBytes(base64Decode(encoded))),
              )
              as Map;
      payload.remove('createdAt');
      return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    } catch (_) {
      return sha256.convert(utf8.encode(encoded)).toString();
    }
  }

  Future<void> dispose() async {
    _generation++;
    _detach();
    try {
      await _running;
    } catch (_) {
      // The status already contains the failure; disposal must still finish.
    }
    await _state?.close();
    status.dispose();
    busy.dispose();
  }
}
