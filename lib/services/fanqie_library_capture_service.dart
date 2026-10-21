import 'platform_channel.dart';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/fanqie_library_capture.dart';
import 'api_client.dart';
import 'backend_transport.dart';

class FanqieLibraryCaptureService {
  static const _account = AppMethodChannel('fqapp/fanqie_account');
  static const _files = AppMethodChannel('fqapp/library_backup');

  Future<FanqieLibraryCapture?> collect(
    BackendRequest request,
    void Function(String) progress, {
    bool? dark,
    bool eink = false,
  }) async {
    final cookie = await _account.invokeMethod<String>('login', {
      'dark': dark,
      'eink': eink,
    });
    if (cookie == null || cookie.isEmpty) return null;
    final run = _Collection(cookie, request, progress);
    return ApiClient.instance.withCancellation(request, run.collect);
  }

  Future<bool> save(FanqieLibraryCapture capture) async =>
      await _files.invokeMethod<bool>('storeFanqieCapture', {
        'bytes': capture.encode(),
      }) ??
      false;

  Future<FanqieLibraryCapture?> latest() async {
    final bytes = await _files.invokeMethod<Uint8List>('latestFanqieCapture');
    return bytes == null ? null : FanqieLibraryCapture.decode(bytes);
  }

  Future<bool> export(FanqieLibraryCapture capture) async =>
      await _files.invokeMethod<
        bool
      >(capture.parts.isEmpty ? 'saveBackup' : 'exportFanqieCapture', {
        'name':
            'fanqie-library-${DateTime.now().millisecondsSinceEpoch}.${capture.parts.isEmpty ? 'json' : 'zip'}',
        'bytes': capture.encode(),
        'parts': capture.parts,
      }) ??
      false;

  Future<FanqieLibraryCapture> completeMetadata(
    FanqieLibraryCapture capture,
    BackendRequest request,
    void Function(String) progress,
  ) => ApiClient.instance.withCancellation(
    request,
    () => _Collection('', request, progress).resumeMetadata(capture),
  );
}

class _CaptureLimit implements Exception {
  _CaptureLimit(this.message);
  final String message;
}

class _CaptureStorage implements Exception {}

class _IdentityChanged implements Exception {}

class _Collection {
  _Collection(this.cookie, this.request, this.progress);
  final String cookie;
  final BackendRequest request;
  final void Function(String) progress;
  final sources = <Map<String, dynamic>>[];
  final parts = <String>[];
  final pending = <Map<String, dynamic>>[];
  final pendingSummaries = <Map<String, dynamic>>[];
  final books = <int, Set<String>>{};
  final folders = <String>{};
  final started = DateTime.now().toUtc().toIso8601String();
  String? deviceId;
  int usedBytes = 0;
  int pendingBytes = 0;
  int redactedFields = 0;
  String stopReason = '';

  Future<FanqieLibraryCapture> collect() async {
    try {
      for (final resource in [
        'shelf_list',
        'shelf_info',
        'topping',
        'tabs',
        'progress_list',
      ]) {
        await _fetch(resource);
      }
      // Exact ReadingBookType values from the official model. Keep every type
      // in the capture; only the separate legacy importer filters novels.
      for (final type in [0, 1, 2, 3, 4, 5, 6, 35]) {
        await _paged('history', type: type);
      }
      await _paged('folder_list');
      for (final folder in folders.toList()) {
        await _paged('folder_detail', folder: folder);
      }
      // Query exact identities instead of guessing progress timestamp paging.
      for (final entry in books.entries.toList()) {
        final ids = entry.value.toList();
        for (var offset = 0; offset < ids.length; offset += 50) {
          await _fetch(
            'progress_batch',
            type: entry.key,
            ids: ids.sublist(offset, (offset + 50).clamp(0, ids.length)),
          );
        }
      }
      // Anonymous metadata can complete missing covers/names. No chapter text
      // or recommendations are downloaded, and no account cookie is forwarded.
      final novelIds = {...?books[0], ...?books[1]};
      for (final id in novelIds) {
        await _metadata(id);
      }
    } on BackendRequestAborted {
      stopReason = '用户取消；已收到的数据保留，尚未请求的部分没有采集';
    } on _CaptureLimit catch (error) {
      stopReason = error.message;
    } on _CaptureStorage {
      stopReason = '本机分卷保存失败；保留已保存的分卷，部分响应未落盘';
    } on _IdentityChanged {
      stopReason = '采集设备不一致，已停止；此文件是部分采集';
    }
    return _finish();
  }

  Future<FanqieLibraryCapture> resumeMetadata(FanqieLibraryCapture seed) async {
    try {
      parts.addAll(seed.parts);
      usedBytes = seed.document['totalResponseBytes'] as int? ?? 0;
      for (final source in seed.sources) {
        final type = _integer(source['bookType']) ?? 0;
        if (source['resource'] != 'book_detail') {
          _identities(source['payload'], type);
        }
        for (final id in source['bookIds'] as List? ?? const []) {
          final value = _id(id);
          if (value != null) {
            books.putIfAbsent(type, () => <String>{}).add(value);
          }
        }
        if (seed.parts.isEmpty) {
          await _add(source);
        } else {
          sources.add(Map<String, dynamic>.from(source));
        }
      }
      final completed = {
        for (final source in sources)
          if (source['resource'] == 'book_detail' &&
              source['status'] == 'received')
            source['bookId'],
      };
      for (final id in {...?books[0], ...?books[1]}) {
        if (!completed.contains(id)) await _metadata(id);
      }
    } on BackendRequestAborted {
      stopReason = '用户取消；已保存的分卷保留，可继续补取详情';
    } on _CaptureLimit catch (error) {
      stopReason = error.message;
    } on _CaptureStorage {
      stopReason = '本机分卷保存失败；保留已保存的分卷，部分响应未落盘';
    }
    return _finish(resumedFrom: seed.document['createdAt']);
  }

  Future<FanqieLibraryCapture> _finish({dynamic resumedFrom}) async {
    try {
      await _flush();
    } on _CaptureStorage {
      stopReason = '本机分卷保存失败；保留已保存的分卷，部分响应未落盘';
      for (final summary in pendingSummaries) {
        summary['status'] = 'failed';
        summary['note'] = '已收到但未能保存原始响应，请重新采集该来源';
      }
    }
    return FanqieLibraryCapture({
      'format': 'fqapp.fanqie-library-capture',
      'version': 2,
      'createdAt': started,
      'finishedAt': DateTime.now().toUtc().toIso8601String(),
      'stopReason': stopReason,
      'resumedFrom': ?resumedFrom,
      'parts': parts,
      'totalResponseBytes': usedBytes,
      'credentialFieldsRemoved': redactedFields,
      'knownLimits': [
        '仅采集固定白名单读取接口，不含正文、账号凭证或上游写操作',
        '接口失败、未授权、分页上限均单独记录，不表示账号无数据',
        '书架 server_time=0 单次快照保留 is_all，不把服务端版本当分页游标',
        'progress_list 为单次观察；按采集到的作品 ID 批量补查进度',
        '原始响应在 parts 列出的 JSON 分卷内；sources 是响应索引，不含正文载荷',
        '续取仅补充公开书籍详情，不刷新之前采集的账号快照',
        '接口版本与网页登录兼容性须以每个响应为准；不保证发现所有云端数据',
        '字段原样保留（移除凭证字段），未映射为本机章节和收藏',
      ],
      'bookCountsByType': {
        for (final e in books.entries) '${e.key}': e.value.length,
      },
      'sources': sources,
    });
  }

  void _check() {
    if (request.isCancelled) throw BackendRequestAborted('已取消');
    if (sources.length >= 2000) {
      throw _CaptureLimit('达到 2000 个响应上限；已保存分卷，可保留部分数据');
    }
  }

  Future<void> _add(Map<String, dynamic> source) async {
    final size = utf8.encode(jsonEncode(source)).length;
    if (size > FanqieLibraryCapture.maxBytes - 128 * 1024) {
      throw _CaptureLimit('单个响应超过分卷大小上限；其他已保存的响应保留');
    }
    if (pending.isNotEmpty && pendingBytes + size > 4 * 1024 * 1024) {
      await _flush();
    }
    usedBytes += size;
    pendingBytes += size;
    pending.add(source);
    final summary = Map<String, dynamic>.from(source)..remove('payload');
    sources.add(summary);
    pendingSummaries.add(summary);
    if (pendingBytes >= 4 * 1024 * 1024) await _flush();
  }

  Future<void> _flush() async {
    if (pending.isEmpty) return;
    try {
      final name = await const AppMethodChannel('fqapp/library_backup')
          .invokeMethod<String>('storeFanqieCapturePart', {
            'bytes': Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'format': 'fqapp.fanqie-library-part',
                  'version': 1,
                  'sources': pending,
                }),
              ),
            ),
          });
      if (name == null ||
          !RegExp(r'^part-[0-9]+-[a-fA-F0-9-]+\.json$').hasMatch(name)) {
        throw _CaptureStorage();
      }
      parts.add(name);
      for (final summary in pendingSummaries) {
        summary['part'] = name;
      }
      pending.clear();
      pendingSummaries.clear();
      pendingBytes = 0;
    } on PlatformException {
      throw _CaptureStorage();
    }
  }

  Future<Map<String, dynamic>?> _fetch(
    String resource, {
    int type = 0,
    int offset = 0,
    List<String> ids = const [],
    String? folder,
  }) async {
    _check();
    progress('正在采集 $resource，已保存 ${sources.length} 个响应');
    final source = <String, dynamic>{
      'resource': resource,
      'bookType': type,
      'offset': offset,
      if (ids.isNotEmpty) 'bookIds': ids,
      'folderId': ?folder,
      'receivedAt': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      final result = await ApiClient.instance.fanqieLibraryResource(
        cookie: cookie,
        resource: resource,
        deviceId: deviceId,
        offset: offset,
        bookType: type,
        bookIds: ids,
        folderId: folder,
      );
      final selected = result['device_id'];
      if (selected is! String ||
          selected.isEmpty ||
          (deviceId != null && selected != deviceId)) {
        throw _IdentityChanged();
      }
      deviceId ??= selected;
      final payload = result['payload'];
      final success =
          result['upstream_status'] == 200 &&
          payload is Map &&
          (payload['code'] == 0 || payload['code'] == '0');
      await _add({
        ...source,
        'status': success ? 'received' : 'failed',
        'upstreamStatus': result['upstream_status'],
        if (result['error'] is String) 'adapterError': _clean(result['error']),
        'payload': _clean(payload),
        if (!success) 'note': '接口未成功；保留响应供后续分析，未当成空书架',
      });
      if (!success) return null;
      _identities(payload, type);
      return Map<String, dynamic>.from(payload);
    } on BackendRequestAborted {
      rethrow;
    } on _CaptureLimit {
      rethrow;
    } on _IdentityChanged {
      rethrow;
    } on _CaptureStorage {
      rethrow;
    } on Exception {
      await _add({
        ...source,
        'status': 'failed',
        'note': '读取失败或响应无效，未保存异常详情和请求凭证',
      });
      return null;
    }
  }

  Future<void> _paged(String resource, {int type = 0, String? folder}) async {
    var offset = 0;
    for (var page = 0; page < 200; page++) {
      final payload = await _fetch(
        resource,
        type: type,
        offset: offset,
        folder: folder,
      );
      if (payload == null) return;
      final data = payload['data'];
      if (data is! Map || data['has_more'] is! bool) {
        await _add({
          'resource': resource,
          'bookType': type,
          'folderId': ?folder,
          'status': 'incomplete',
          'note': '缺少明确分页字段，未假定已采集完毕',
        });
        return;
      }
      if (data['has_more'] == false) return;
      final next = _integer(data['next_offset']);
      if (next == null || next <= offset || next > 100000) {
        await _add({
          'resource': resource,
          'bookType': type,
          'folderId': ?folder,
          'status': 'incomplete',
          'note': '分页未前进或超过游标范围',
        });
        return;
      }
      offset = next;
    }
    _add({
      'resource': resource,
      'bookType': type,
      'folderId': ?folder,
      'status': 'incomplete',
      'note': '达到 200 页上限',
    });
  }

  Future<void> _metadata(String id) async {
    _check();
    progress('正在补充书籍详情，已保存 ${sources.length} 个响应');
    try {
      final payload = await ApiClient.instance.fanqieBookMetadata(id);
      await _add({
        'resource': 'book_detail',
        'bookId': id,
        'status': 'received',
        'payload': _clean(payload),
      });
    } on BackendRequestAborted {
      rethrow;
    } on _CaptureLimit {
      rethrow;
    } on _CaptureStorage {
      rethrow;
    } on Exception {
      await _add({
        'resource': 'book_detail',
        'bookId': id,
        'status': 'failed',
        'note': '详情未能获取，保留其他来源记录',
      });
    }
  }

  static int? _integer(dynamic value) =>
      value is int ? value : int.tryParse('$value');
  static String? _id(dynamic value) {
    if (value is! String && value is! int) return null;
    final text = '$value';
    final number = int.tryParse(text);
    return RegExp(r'^[0-9]{1,19}$').hasMatch(text) &&
            number != null &&
            number > 0
        ? text
        : null;
  }

  void _identities(dynamic node, int type, [int depth = 0]) {
    if (depth > 32) return;
    if (node is List) {
      for (final child in node) {
        _identities(child, type, depth + 1);
      }
    } else if (node is Map) {
      final currentType = _integer(node['book_type']) ?? type;
      final id = _id(node['book_id_str']) ?? _id(node['book_id']);
      if (id != null && const {0, 1, 2, 3, 4, 5, 6, 35}.contains(currentType)) {
        books.putIfAbsent(currentType, () => <String>{}).add(id);
      }
      final folder = _id(node['folder_id']);
      if (folder != null && folder != '0') folders.add(folder);
      for (final child in node.values) {
        _identities(child, currentType, depth + 1);
      }
    }
  }

  static final _credentialKey = RegExp(
    r'cookie|token|^session(?:id)?(?:_ss)?$|^sid_tt$|^sid_guard$|authorization|password|secret|device.?id|install.?id|^iid$|^headers$',
    caseSensitive: false,
  );
  dynamic _clean(dynamic node, [int depth = 0]) {
    if (depth > 48) throw const FormatException('响应嵌套过深');
    if (node is Map) {
      final result = <String, dynamic>{};
      for (final entry in node.entries) {
        final key = '${entry.key}';
        if (_credentialKey.hasMatch(key)) {
          redactedFields++;
          continue;
        }
        result[key] = _clean(entry.value, depth + 1);
      }
      return result;
    }
    if (node is List) {
      return [for (final value in node) _clean(value, depth + 1)];
    }
    if (node is String) {
      var value = cookie.isEmpty ? node : node.replaceAll(cookie, '[removed]');
      value = value.replaceAll(
        RegExp(
          r'(?:sessionid(?:_ss)?|sid_tt|sid_guard|passport_csrf_token)=[^;\s&]+',
          caseSensitive: false,
        ),
        '[removed]',
      );
      final uri = Uri.tryParse(value);
      if (uri != null &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          (uri.userInfo.isNotEmpty ||
              uri.queryParameters.keys.any(_credentialKey.hasMatch))) {
        redactedFields++;
        value = uri
            .replace(
              userInfo: '',
              queryParameters: {
                for (final e in uri.queryParametersAll.entries)
                  if (!_credentialKey.hasMatch(e.key)) e.key: e.value,
              },
            )
            .toString();
      }
      return value;
    }
    return node;
  }
}
