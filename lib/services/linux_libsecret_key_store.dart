import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'secure_key_storage.dart';

/// Linux backend: libsecret (Secret Service over D-Bus), the same store
/// `flutter_secure_storage_linux` used. One libsecret item holds the whole
/// `{key: value}` map as JSON, mirroring that plugin so the store format is
/// simple and there is exactly one D-Bus round trip per operation.
///
/// The calls are synchronous FFI, so each one runs in a short-lived isolate:
/// a locked or cold keyring must never block the UI isolate that awaits the
/// key during bootstrap.
///
/// Failure policy mirrors `flutter_secure_storage_linux`: an unavailable
/// keyring throws instead of reporting "no key", so `SecureKeyProvider` fails
/// closed rather than minting a replacement key (and thereby quarantining the
/// existing encrypted boxes).
class LinuxLibsecretKeyStore implements SecureKeyStorage {
  // 一次 libsecret 条目存整个 map，read-modify-write 不能并发，否则两个密钥
  // 同时创建时会丢掉后写的那个（下次启动就会另建新密钥）。
  static Future<void> _tail = Future<void>.value();

  static Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<String?> read(String key) => _serial(
    () => Isolate.run(
      () => _withSchema((api, schema) {
        final items = _readAll(api, schema);
        return items[key];
      }),
    ),
  );

  @override
  Future<void> write(String key, String value) => _serial(
    () => Isolate.run(() {
      _withSchema((api, schema) {
        final items = _readAll(api, schema)..[key] = value;
        _writeAll(api, schema, items);
        return null;
      });
    }),
  );

  @override
  Future<void> delete(String key) => _serial(
    () => Isolate.run(() {
      _withSchema((api, schema) {
        final items = _readAll(api, schema)..remove(key);
        if (items.isEmpty) {
          _clearAll(api, schema);
        } else {
          _writeAll(api, schema, items);
        }
        return null;
      });
    }),
  );

  static const _schemaName = 'com.fqapp.fqapp.secure_keys';
  static const _attributeName = 'account';
  static const _attributeValue = 'fqapp_secure_keys_v1';
  static const _label = '什锦铺本机密钥';

  /// C 结构体自检：libsecret `SecretSchema` 在 64 位 ABI 下为 592 字节
  /// （name 8 + flags 4 + 32×16 attributes + reserved 4 + 7×8 保留指针 + 对齐）。
  /// 布局错位会让 libsecret 读到垃圾指针，所以单元测试会在宿主上先核对尺寸。
  @visibleForTesting
  static int get debugSecretSchemaSize => sizeOf<_SecretSchema>();

  /// 同上：单个属性的声明项为 `{const gchar *name; SecretSchemaAttributeType type;} = 16`。
  @visibleForTesting
  static int get debugSecretSchemaAttributeSize =>
      sizeOf<_SecretSchemaAttribute>();

  static Map<String, String> _readAll(_Libsecret api, _SchemaRef schema) {
    final error = calloc<Pointer<_GError>>();
    final attributes = _attributes(api, schema);
    try {
      final result = api.lookupv(schema.pointer, attributes, nullptr, error);
      _throwOnError(api, error, 'lookup');
      if (result == nullptr) return <String, String>{};
      try {
        final text = result.toDartString();
        if (text.isEmpty) return <String, String>{};
        final decoded = jsonDecode(text);
        if (decoded is! Map) {
          throw const LinuxKeyringException('密钥条目不是对象');
        }
        return {
          for (final entry in decoded.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        };
      } finally {
        api.passwordFree(result);
      }
    } finally {
      api.hashTableDestroy(attributes);
      calloc.free(error);
    }
  }

  static void _writeAll(
    _Libsecret api,
    _SchemaRef schema,
    Map<String, String> items,
  ) {
    final error = calloc<Pointer<_GError>>();
    final attributes = _attributes(api, schema);
    final label = _label.toNativeUtf8();
    final password = jsonEncode(items).toNativeUtf8();
    try {
      // Warm the service so a cold keyring has its collections loaded; without
      // it the first lookup in a fresh session can report "absent" and the app
      // would create a second key beside the existing one.
      _warmup(api, error);
      final ok = api.storev(
        schema.pointer,
        attributes,
        nullptr,
        label,
        password,
        nullptr,
        error,
      );
      _throwOnError(api, error, 'store');
      if (ok == 0) throw const LinuxKeyringException('密钥写入被拒绝');
    } finally {
      malloc.free(label);
      malloc.free(password);
      api.hashTableDestroy(attributes);
      calloc.free(error);
    }
  }

  static void _clearAll(_Libsecret api, _SchemaRef schema) {
    final error = calloc<Pointer<_GError>>();
    final attributes = _attributes(api, schema);
    try {
      final ok = api.clearv(schema.pointer, attributes, nullptr, error);
      _throwOnError(api, error, 'clear');
      if (ok == 0) throw const LinuxKeyringException('密钥删除被拒绝');
    } finally {
      api.hashTableDestroy(attributes);
      calloc.free(error);
    }
  }

  static void _warmup(_Libsecret api, Pointer<Pointer<_GError>> error) {
    // SECRET_SERVICE_OPEN_SESSION | SECRET_SERVICE_LOAD_COLLECTIONS
    final service = api.serviceGetSync(0x2 | 0x4, nullptr, error);
    _throwOnError(api, error, 'service');
    if (service == nullptr) {
      throw const LinuxKeyringException('密钥服务不可用');
    }
    api.objectUnref(service);
  }

  static Pointer<Void> _attributes(_Libsecret api, _SchemaRef schema) {
    final table = api.hashTableNewFull(
      api.gStrHash.cast(),
      api.gStrEqual.cast(),
      api.gFree.cast(),
      api.gFree.cast(),
    );
    final name = _attributeName.toNativeUtf8();
    final value = _attributeValue.toNativeUtf8();
    try {
      // g_hash_table_new_full() owns the copies (key/value destroy = g_free).
      api.hashTableInsert(
        table,
        api.strDup(name).cast(),
        api.strDup(value).cast(),
      );
    } finally {
      malloc.free(name);
      malloc.free(value);
    }
    return table;
  }

  static void _throwOnError(
    _Libsecret api,
    Pointer<Pointer<_GError>> error,
    String call,
  ) {
    final errorPointer = error.value;
    if (errorPointer == nullptr) return;
    final message = errorPointer.ref.message == nullptr
        ? '未知错误'
        : errorPointer.ref.message.toDartString();
    api.gErrorFree(errorPointer);
    error.value = nullptr;
    throw LinuxKeyringException('libsecret $call: $message');
  }

  static T _withSchema<T>(T Function(_Libsecret, _SchemaRef) body) {
    final api = _Libsecret.instance;
    final schema = _SchemaRef();
    try {
      return body(api, schema);
    } finally {
      schema.dispose();
    }
  }
}

class LinuxKeyringException implements Exception {
  const LinuxKeyringException(this.message);

  final String message;

  @override
  String toString() => 'LinuxKeyringException: $message';
}

/// Owns the `SecretSchema` struct and the UTF-8 strings it points at.
class _SchemaRef {
  _SchemaRef() {
    pointer = calloc<_SecretSchema>();
    _name = LinuxLibsecretKeyStore._schemaName.toNativeUtf8();
    _attribute = LinuxLibsecretKeyStore._attributeName.toNativeUtf8();
    pointer.ref.name = _name;
    pointer.ref.flags = 0;
    pointer.ref.attributes[0].name = _attribute;
    pointer.ref.attributes[0].type = 0; // SECRET_SCHEMA_ATTRIBUTE_STRING
  }

  late final Pointer<_SecretSchema> pointer;
  late final Pointer<Utf8> _name;
  late final Pointer<Utf8> _attribute;

  void dispose() {
    malloc.free(_name);
    malloc.free(_attribute);
    calloc.free(pointer);
  }
}

// --- libsecret / GLib FFI ----------------------------------------------------

final class _GError extends Struct {
  @Uint32()
  external int domain;

  @Int32()
  external int code;

  external Pointer<Utf8> message;
}

final class _SecretSchemaAttribute extends Struct {
  external Pointer<Utf8> name;

  @Int32()
  external int type;
}

final class _SecretSchema extends Struct {
  external Pointer<Utf8> name;

  @Int32()
  external int flags;

  @Array(32)
  external Array<_SecretSchemaAttribute> attributes;

  @Uint32()
  external int reserved;

  external Pointer<Void> reserved1;
  external Pointer<Void> reserved2;
  external Pointer<Void> reserved3;
  external Pointer<Void> reserved4;
  external Pointer<Void> reserved5;
  external Pointer<Void> reserved6;
  external Pointer<Void> reserved7;
}

typedef _HashTableNewFullNative =
    Pointer<Void> Function(
      Pointer<Void> hash,
      Pointer<Void> equal,
      Pointer<Void> keyDestroy,
      Pointer<Void> valueDestroy,
    );
typedef _HashTableNewFullDart =
    Pointer<Void> Function(
      Pointer<Void> hash,
      Pointer<Void> equal,
      Pointer<Void> keyDestroy,
      Pointer<Void> valueDestroy,
    );

typedef _HashTableInsertNative =
    Void Function(Pointer<Void> table, Pointer<Utf8> key, Pointer<Utf8> value);
typedef _HashTableInsertDart =
    void Function(Pointer<Void> table, Pointer<Utf8> key, Pointer<Utf8> value);

typedef _HashTableDestroyNative = Void Function(Pointer<Void> table);
typedef _HashTableDestroyDart = void Function(Pointer<Void> table);

typedef _StrdupNative = Pointer<Utf8> Function(Pointer<Utf8> value);
typedef _StrdupDart = Pointer<Utf8> Function(Pointer<Utf8> value);

typedef _GErrorFreeNative = Void Function(Pointer<_GError> error);
typedef _GErrorFreeDart = void Function(Pointer<_GError> error);

typedef _ObjectUnrefNative = Void Function(Pointer<Void> object);
typedef _ObjectUnrefDart = void Function(Pointer<Void> object);

typedef _StorevNative =
    Int32 Function(
      Pointer<_SecretSchema> schema,
      Pointer<Void> attributes,
      Pointer<Utf8> collection,
      Pointer<Utf8> label,
      Pointer<Utf8> password,
      Pointer<Void> cancellable,
      Pointer<Pointer<_GError>> error,
    );
typedef _StorevDart =
    int Function(
      Pointer<_SecretSchema> schema,
      Pointer<Void> attributes,
      Pointer<Utf8> collection,
      Pointer<Utf8> label,
      Pointer<Utf8> password,
      Pointer<Void> cancellable,
      Pointer<Pointer<_GError>> error,
    );

typedef _LookupvNative =
    Pointer<Utf8> Function(
      Pointer<_SecretSchema> schema,
      Pointer<Void> attributes,
      Pointer<Void> cancellable,
      Pointer<Pointer<_GError>> error,
    );
typedef _LookupvDart =
    Pointer<Utf8> Function(
      Pointer<_SecretSchema> schema,
      Pointer<Void> attributes,
      Pointer<Void> cancellable,
      Pointer<Pointer<_GError>> error,
    );

typedef _ClearvNative =
    Int32 Function(
      Pointer<_SecretSchema> schema,
      Pointer<Void> attributes,
      Pointer<Void> cancellable,
      Pointer<Pointer<_GError>> error,
    );
typedef _ClearvDart =
    int Function(
      Pointer<_SecretSchema> schema,
      Pointer<Void> attributes,
      Pointer<Void> cancellable,
      Pointer<Pointer<_GError>> error,
    );

typedef _ServiceGetSyncNative =
    Pointer<Void> Function(
      Uint32 flags,
      Pointer<Void> cancellable,
      Pointer<Pointer<_GError>> error,
    );
typedef _ServiceGetSyncDart =
    Pointer<Void> Function(
      int flags,
      Pointer<Void> cancellable,
      Pointer<Pointer<_GError>> error,
    );

typedef _PasswordFreeNative = Void Function(Pointer<Utf8> password);
typedef _PasswordFreeDart = void Function(Pointer<Utf8> password);

class _Libsecret {
  _Libsecret._(DynamicLibrary secret, DynamicLibrary glib)
    : storev = secret.lookupFunction<_StorevNative, _StorevDart>(
        'secret_password_storev_sync',
      ),
      lookupv = secret.lookupFunction<_LookupvNative, _LookupvDart>(
        'secret_password_lookupv_sync',
      ),
      clearv = secret.lookupFunction<_ClearvNative, _ClearvDart>(
        'secret_password_clearv_sync',
      ),
      passwordFree = secret
          .lookupFunction<_PasswordFreeNative, _PasswordFreeDart>(
            'secret_password_free',
          ),
      serviceGetSync = secret
          .lookupFunction<_ServiceGetSyncNative, _ServiceGetSyncDart>(
            'secret_service_get_sync',
          ),
      hashTableNewFull = glib
          .lookupFunction<_HashTableNewFullNative, _HashTableNewFullDart>(
            'g_hash_table_new_full',
          ),
      hashTableInsert = glib
          .lookupFunction<_HashTableInsertNative, _HashTableInsertDart>(
            'g_hash_table_insert',
          ),
      hashTableDestroy = glib
          .lookupFunction<_HashTableDestroyNative, _HashTableDestroyDart>(
            'g_hash_table_destroy',
          ),
      strDup = glib.lookupFunction<_StrdupNative, _StrdupDart>('g_strdup'),
      gErrorFree = glib.lookupFunction<_GErrorFreeNative, _GErrorFreeDart>(
        'g_error_free',
      ),
      objectUnref = glib.lookupFunction<_ObjectUnrefNative, _ObjectUnrefDart>(
        'g_object_unref',
      ),
      gFree = glib.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        'g_free',
      ),
      gStrHash = glib.lookup<NativeFunction<Uint32 Function(Pointer<Utf8>)>>(
        'g_str_hash',
      ),
      gStrEqual = glib
          .lookup<NativeFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>)>>(
            'g_str_equal',
          );

  static final instance = _Libsecret._(
    DynamicLibrary.open('libsecret-1.so.0'),
    DynamicLibrary.open('libglib-2.0.so.0'),
  );

  final _StorevDart storev;
  final _LookupvDart lookupv;
  final _ClearvDart clearv;
  final _PasswordFreeDart passwordFree;
  final _ServiceGetSyncDart serviceGetSync;
  final _HashTableNewFullDart hashTableNewFull;
  final _HashTableInsertDart hashTableInsert;
  final _HashTableDestroyDart hashTableDestroy;
  final _StrdupDart strDup;
  final _GErrorFreeDart gErrorFree;
  final _ObjectUnrefDart objectUnref;
  final Pointer<NativeFunction<Void Function(Pointer<Void>)>> gFree;
  final Pointer<NativeFunction<Uint32 Function(Pointer<Utf8>)>> gStrHash;
  final Pointer<NativeFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>)>>
  gStrEqual;
}
