import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

import 'app_log.dart';

typedef _OpenNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _Open = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);

String desktopCoreLibraryPath() {
  final bundled = File(
    '${File(Platform.resolvedExecutable).parent.path}/fqapi_core.dll',
  );
  if (bundled.existsSync()) return bundled.path;
  return File('rust/target/release/fqapi_core.dll').absolute.path;
}

/// A failed media session open. [message] is a fixed user-facing string from
/// the native core; it never carries the URL or key.
class DesktopMediaException implements Exception {
  const DesktopMediaException(
    this.message, {
    this.kind = 'other',
    this.httpStatus,
  });

  final String message;

  /// connect / timeout / http / range / file / decrypt / other.
  final String kind;
  final int? httpStatus;

  /// The Media3 `PlaybackException` code with the same meaning, so desktop
  /// failures reach the same [PlaybackIssue] texts as Android ones.
  int? get errorCode => switch (kind) {
    'connect' => 2001, // IO_NETWORK_CONNECTION_FAILED
    'timeout' => 2002, // IO_NETWORK_CONNECTION_TIMEOUT
    'http' || 'range' => 2004, // IO_BAD_HTTP_STATUS
    'file' => 2005, // IO_FILE_NOT_FOUND
    'decrypt' => 3001, // PARSING_CONTAINER_MALFORMED
    _ => null,
  };

  @override
  String toString() => 'DesktopMediaException($kind)';
}

/// The `error` event payload for a player whose media failed to open, in the
/// shape `NativePlaybackException.fromEvent` reads. Logs only the category.
Map<String, Object> desktopOpenFailure(int playerId, Object error) {
  final failure = error is DesktopMediaException ? error : null;
  AppLog.d(
    'desktop-player',
    'id=$playerId open failed kind=${failure?.kind ?? 'player'} '
        'status=${failure?.httpStatus}',
  );
  return {
    'message': '媒体加载失败，请检查网络或重试',
    'errorCode': ?failure?.errorCode,
    'httpStatusCode': ?failure?.httpStatus,
  };
}

class DesktopMedia {
  DesktopMedia._(this.id, this.url, this.libraryPath);
  final String id;
  final String url;
  final String libraryPath;
  bool _closed = false;

  static Future<DesktopMedia> open(String url, String key) async {
    final path = desktopCoreLibraryPath();
    // Metadata probing performs synchronous native I/O, away from the UI isolate.
    final result = await Isolate.run(() {
      final lib = DynamicLibrary.open(path);
      final open = lib.lookupFunction<_OpenNative, _Open>(
        'fq_desktop_media_open',
      );
      final free = lib.lookupFunction<_FreeNative, _Free>(
        'fq_desktop_media_free',
      );
      final request = jsonEncode({'url': url, 'key': key}).toNativeUtf8();
      try {
        final response = open(request);
        if (response == nullptr) throw StateError('无法创建媒体会话');
        try {
          return jsonDecode(response.toDartString()) as Map<String, dynamic>;
        } finally {
          free(response);
        }
      } finally {
        calloc.free(request);
      }
    });
    if (result['error'] case final String error) {
      throw DesktopMediaException(
        error,
        kind: result['kind'] is String ? result['kind'] as String : 'other',
        httpStatus: result['status'] is int ? result['status'] as int : null,
      );
    }
    return DesktopMedia._(
      result['id'] as String,
      result['url'] as String,
      path,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final lib = DynamicLibrary.open(libraryPath);
    final close = lib.lookupFunction<_FreeNative, _Free>(
      'fq_desktop_media_close',
    );
    final value = id.toNativeUtf8();
    try {
      close(value);
    } finally {
      calloc.free(value);
    }
  }
}
