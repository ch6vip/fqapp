import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

import 'secure_key_storage.dart';

/// Windows backend: DPAPI (`CryptProtectData`) under the current user's logon
/// credentials, persisted as one protected blob under the app support
/// directory.
///
/// DPAPI decrypts only for the same Windows user on the same machine, so the
/// file is useless when copied to another account. This is the same primitive
/// `flutter_secure_storage_windows` used, which is why removing that package
/// does not weaken key protection here — it only removes the `win32` 5.x
/// dependency that blocked the plugin upgrades in #205.
///
/// Layout: `secure_keys.dpapi` (JSON `{v:1, items:{...}}`, DPAPI-protected).
/// Writes rotate a `.bak` copy first, so a crash mid-write still leaves a
/// readable key file instead of silently minting a new key.
class WindowsDpapiKeyStore implements SecureKeyStorage {
  WindowsDpapiKeyStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const _fileName = 'secure_keys.dpapi';
  static const _backupFileName = 'secure_keys.dpapi.bak';
  static const _entropy = [
    0x66,
    0x71,
    0x61,
    0x70,
    0x70,
    0x2f,
    0x6b,
    0x65,
    0x79,
    0x73,
    0x2f,
    0x76,
    0x31,
  ];
  static const _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

  final Future<Directory> Function() _directory;
  Map<String, String>? _cache;
  Future<void> _pending = Future<void>.value();

  @override
  Future<String?> read(String key) async => (await _load())[key];

  @override
  Future<void> write(String key, String value) => _enqueue(() async {
    final items = Map<String, String>.from(await _load())..[key] = value;
    await _persist(items);
  });

  @override
  Future<void> delete(String key) => _enqueue(() async {
    final items = Map<String, String>.from(await _load())..remove(key);
    await _persist(items);
  });

  /// Serializes writers: two concurrent key writes must not interleave their
  /// rotate/rename steps and lose the newer map.
  Future<void> _enqueue(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<Map<String, String>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    Object? failure;
    for (final file in await _candidates()) {
      if (!file.existsSync()) continue;
      try {
        return _cache = _readFile(file);
      } catch (error) {
        // A blob that exists but does not unprotect is *not* "no key": say so,
        // so the provider fails closed instead of minting a replacement key.
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
    return _cache = <String, String>{};
  }

  /// Main file first, then the rotated `.bak` left by an interrupted write.
  Future<List<File>> _candidates() async {
    final directory = await _directory();
    return [
      File('${directory.path}${Platform.pathSeparator}$_fileName'),
      File('${directory.path}${Platform.pathSeparator}$_backupFileName'),
    ];
  }

  Map<String, String> _readFile(File file) {
    final plain = _unprotect(file.readAsBytesSync());
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map) {
      throw const FormatException('密钥文件不是 JSON 对象');
    }
    final items = decoded['items'];
    if (items is! Map) {
      throw const FormatException('密钥文件缺少 items');
    }
    return {
      for (final entry in items.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  Future<void> _persist(Map<String, String> items) async {
    final plain = Uint8List.fromList(
      utf8.encode(jsonEncode({'v': 1, 'items': items})),
    );
    final blob = _protect(plain);
    final directory = await _directory();
    await directory.create(recursive: true);
    final target = File('${directory.path}${Platform.pathSeparator}$_fileName');
    final backup = File(
      '${directory.path}${Platform.pathSeparator}$_backupFileName',
    );
    final temp = File('${target.path}.tmp');
    await temp.writeAsBytes(blob, flush: true);
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    await temp.rename(target.path);
    _cache = items;
  }

  Uint8List _protect(Uint8List plain) {
    final api = _Dpapi.instance;
    final input = calloc<_DataBlob>();
    final entropy = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final inputBuffer = malloc<Uint8>(plain.isEmpty ? 1 : plain.length);
    final entropyBuffer = malloc<Uint8>(_entropy.length);
    try {
      inputBuffer.asTypedList(plain.length).setAll(0, plain);
      input.ref
        ..cbData = plain.length
        ..pbData = inputBuffer;
      entropyBuffer.asTypedList(_entropy.length).setAll(0, _entropy);
      entropy.ref
        ..cbData = _entropy.length
        ..pbData = entropyBuffer;
      final ok = api.protect(
        input,
        nullptr,
        entropy,
        nullptr,
        nullptr,
        _uiForbidden,
        output,
      );
      if (ok == 0) {
        throw WindowsDpapiException('CryptProtectData', api.lastError());
      }
      return _copyOut(output.ref);
    } finally {
      _release(api, output, inputBuffer, entropyBuffer, input, entropy);
    }
  }

  Uint8List _unprotect(Uint8List blob) {
    final api = _Dpapi.instance;
    final input = calloc<_DataBlob>();
    final entropy = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final inputBuffer = malloc<Uint8>(blob.isEmpty ? 1 : blob.length);
    final entropyBuffer = malloc<Uint8>(_entropy.length);
    try {
      inputBuffer.asTypedList(blob.length).setAll(0, blob);
      input.ref
        ..cbData = blob.length
        ..pbData = inputBuffer;
      entropyBuffer.asTypedList(_entropy.length).setAll(0, _entropy);
      entropy.ref
        ..cbData = _entropy.length
        ..pbData = entropyBuffer;
      final ok = api.unprotect(
        input,
        nullptr,
        entropy,
        nullptr,
        nullptr,
        _uiForbidden,
        output,
      );
      if (ok == 0) {
        throw WindowsDpapiException('CryptUnprotectData', api.lastError());
      }
      return _copyOut(output.ref);
    } finally {
      _release(api, output, inputBuffer, entropyBuffer, input, entropy);
    }
  }

  static Uint8List _copyOut(_DataBlob blob) =>
      Uint8List.fromList(blob.pbData.asTypedList(blob.cbData));

  static void _release(
    _Dpapi api,
    Pointer<_DataBlob> output,
    Pointer<Uint8> inputBuffer,
    Pointer<Uint8> entropyBuffer,
    Pointer<_DataBlob> input,
    Pointer<_DataBlob> entropy,
  ) {
    final out = output.ref.pbData;
    if (out != nullptr) api.localFree(out.cast());
    malloc.free(inputBuffer);
    malloc.free(entropyBuffer);
    calloc.free(input);
    calloc.free(entropy);
    calloc.free(output);
  }
}

class WindowsDpapiException implements Exception {
  WindowsDpapiException(this.call, this.errorCode);

  final String call;
  final int errorCode;

  @override
  String toString() => '$call failed (Win32 error $errorCode)';
}

// --- DPAPI FFI ---------------------------------------------------------------

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _ProtectNative =
    Int32 Function(
      Pointer<_DataBlob> input,
      Pointer<Utf16> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      Uint32 flags,
      Pointer<_DataBlob> output,
    );
typedef _ProtectDart =
    int Function(
      Pointer<_DataBlob> input,
      Pointer<Utf16> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      int flags,
      Pointer<_DataBlob> output,
    );

typedef _UnprotectNative =
    Int32 Function(
      Pointer<_DataBlob> input,
      Pointer<Pointer<Utf16>> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      Uint32 flags,
      Pointer<_DataBlob> output,
    );
typedef _UnprotectDart =
    int Function(
      Pointer<_DataBlob> input,
      Pointer<Pointer<Utf16>> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      int flags,
      Pointer<_DataBlob> output,
    );

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

typedef _LastErrorNative = Uint32 Function();
typedef _LastErrorDart = int Function();

class _Dpapi {
  _Dpapi._(DynamicLibrary crypt32, DynamicLibrary kernel32)
    : protect = crypt32.lookupFunction<_ProtectNative, _ProtectDart>(
        'CryptProtectData',
      ),
      unprotect = crypt32.lookupFunction<_UnprotectNative, _UnprotectDart>(
        'CryptUnprotectData',
      ),
      localFree = kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>(
        'LocalFree',
      ),
      lastError = kernel32.lookupFunction<_LastErrorNative, _LastErrorDart>(
        'GetLastError',
      );

  static final instance = _Dpapi._(
    DynamicLibrary.open('crypt32.dll'),
    DynamicLibrary.open('kernel32.dll'),
  );

  final _ProtectDart protect;
  final _UnprotectDart unprotect;
  final _LocalFreeDart localFree;
  final _LastErrorDart lastError;
}
