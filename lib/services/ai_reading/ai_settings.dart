import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../encrypted_hive.dart';
import 'ai_client.dart';
import 'ai_models.dart';
import 'ai_prompt.dart';

/// Persistent field-level settings: built-in defaults -> global -> book.
///
/// Keys are kept in a single encrypted settings box. Credentials themselves
/// live in platform secure storage and only a random `credentialRef` appears
/// here. A malformed entry falls back to defaults instead of blocking reading.
class AiSettingsStore extends ChangeNotifier {
  AiSettingsStore._();
  static final instance = AiSettingsStore._();

  static const boxName = 'ai_settings_v1';
  static const _globalKey = 'global';
  static const _deviceKey = 'device';
  static const _providerPrefix = 'provider:';
  static const _capabilityPrefix = 'capability:';
  static const _bookPrefix = 'book:';
  static const _ratePrefix = 'rate:';

  Box<dynamic>? _box;
  Future<void>? _initFuture;
  bool _available = true;
  String? _status;
  Future<void>? _pendingWrite;

  AiGlobalSettings _global = const AiGlobalSettings();
  AiDeviceSettings _device = const AiDeviceSettings();
  final _providers = <String, AiProviderProfile>{};
  final _capabilities = <String, AiModelCapability>{};
  final _bookOverrides = <String, Map<String, dynamic>>{};
  final _rates = <String, AiRateProfile>{};

  AiGlobalSettings get global => _global;
  AiDeviceSettings get device => _device;
  bool get isAvailable => _available;
  String? get status => _status;
  List<AiProviderProfile> get providers =>
      _providers.values.toList(growable: false)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  List<AiModelCapability> get capabilities =>
      _capabilities.values.toList(growable: false);

  AiProviderProfile? provider(String? id) => id == null ? null : _providers[id];

  List<AiRateProfile> get rates =>
      _rates.values.toList(growable: false)
        ..sort((a, b) => a.label.compareTo(b.label));

  AiRateProfile? rate(String? id) => id == null ? null : _rates[id];

  /// Exact provider+model wins, then provider-wide, then the explicitly
  /// selected profile. This lets one provider have a reasoning-model price and
  /// a cheaper chat-model price without duplicating the endpoint.
  AiRateProfile? rateFor(String providerId, String modelId) {
    AiRateProfile? exact;
    AiRateProfile? providerWide;
    AiRateProfile? universal;
    for (final rate in _rates.values) {
      if (rate.providerId == providerId && rate.modelId == modelId) {
        exact = rate;
      } else if (rate.providerId == providerId && rate.modelId == null) {
        providerWide = rate;
      } else if (rate.providerId == null && rate.modelId == null) {
        universal = rate;
      }
    }
    return exact ??
        providerWide ??
        universal ??
        rate(_global.usagePriceProfile);
  }

  AiModelCapability? capabilityFor({
    required String providerId,
    required String modelId,
    required AiOutputMode mode,
    required String baseUrl,
  }) {
    final key = capabilityKey(
      providerId: providerId,
      modelId: modelId,
      mode: mode,
      baseUrl: baseUrl,
    );
    return _capabilities[key];
  }

  static String capabilityKey({
    required String providerId,
    required String modelId,
    required AiOutputMode mode,
    required String baseUrl,
  }) => AiSettingsCapabilityKey.of(
    providerId: providerId,
    baseUrl: baseUrl,
    modelId: modelId,
    mode: mode,
  );

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      _box = await EncryptedHive.openBox<dynamic>(
        Hive,
        boxName,
        requireEncryption: true,
      );
      for (final key in _box!.keys) {
        final value = _box!.get(key);
        if (key == _globalKey) {
          _global = AiGlobalSettings.fromJson(value);
        } else if (key == _deviceKey) {
          _device = AiDeviceSettings.fromJson(value);
        } else if (key is String && key.startsWith(_providerPrefix)) {
          final profile = AiProviderProfile.fromJson(value);
          if (profile != null) _providers[profile.id] = profile;
        } else if (key is String && key.startsWith(_capabilityPrefix)) {
          final capability = AiModelCapability.fromJson(value);
          if (capability != null) _capabilities[capability.key] = capability;
        } else if (key is String && key.startsWith(_bookPrefix)) {
          final map = _map(value);
          if (map != null) {
            _bookOverrides[key.substring(_bookPrefix.length)] = map;
          }
        } else if (key is String && key.startsWith(_ratePrefix)) {
          final rate = AiRateProfile.fromJson(value);
          if (rate != null) _rates[rate.id] = rate;
        }
      }
      _available = true;
      _status = null;
      // A brand-new install gets a DeepSeek profile shell so the settings page
      // has a concrete place to paste the key. No key or consent is implied.
      if (_providers.isEmpty) {
        await _seedDeepSeek();
      }
    } catch (error) {
      _available = false;
      _status = 'AI 设置存储不可用：$error';
      _global = const AiGlobalSettings();
    } finally {
      notifyListeners();
    }
  }

  Future<void> _seedDeepSeek() async {
    final now = DateTime.now();
    final profile = AiProviderProfile(
      id: 'deepseek',
      label: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      credentialRef: _newCredentialRef(),
      outputMode: AiOutputMode.jsonObject,
      models: const ['deepseek-flash', 'deepseek-v4-pro'],
      createdAt: now,
      updatedAt: now,
    );
    _providers[profile.id] = profile;
    await _box?.put('$_providerPrefix${profile.id}', profile.toJson());
    if (_global.providerId == null) {
      _global = _global.copyWith(
        providerId: profile.id,
        modelId: profile.models.first,
      );
      await _box?.put(_globalKey, _global.toJson());
    }
  }

  Map<String, dynamic> bookOverrides(String bookId) =>
      Map.unmodifiable(_bookOverrides[bookId] ?? const {});

  /// Read-only snapshot used by the portable backup. Provider profiles and
  /// credentials are deliberately excluded.
  Map<String, Map<String, dynamic>> get allBookOverrides => {
    for (final entry in _bookOverrides.entries)
      entry.key: Map.unmodifiable(entry.value),
  };

  AiEffectiveSettings resolve(String bookId) {
    final overrides = _bookOverrides[bookId] ?? const <String, dynamic>{};
    final sources = <String, String>{};
    T value<T>(String key, T globalValue, {String? source}) {
      if (overrides.containsKey(key)) {
        final raw = overrides[key];
        sources[key] = 'book';
        return _coerce<T>(raw) ?? globalValue;
      }
      sources[key] = source ?? 'global';
      return globalValue;
    }

    final enabled = value('enabled', _global.enabled);
    final displayMode = value('displayMode', _global.displayMode);
    final providerId = value<String?>(
      'providerId',
      _global.providerId,
      source: _global.providerId == null ? 'builtin' : 'global',
    );
    final modelId = value<String?>(
      'modelId',
      _global.modelId,
      source: _global.modelId == null ? 'builtin' : 'global',
    );
    final behaviorPrompt = overrides.containsKey('behaviorPrompt')
        ? (overrides['behaviorPrompt'] as String?)
        : _global.behaviorPrompt;
    sources['behaviorPrompt'] = overrides.containsKey('behaviorPrompt')
        ? 'book'
        : _global.behaviorPrompt != null
        ? 'global'
        : 'builtin';
    return AiEffectiveSettings(
      global: _global,
      enabled: enabled,
      displayMode: displayMode,
      providerId: providerId,
      modelId: modelId,
      behaviorPrompt: behaviorPrompt,
      prefetchEnabled: value('prefetchEnabled', _global.prefetchEnabled),
      prefetchTriggerRatio: value(
        'prefetchTriggerRatio',
        _global.prefetchTriggerRatio,
      ),
      maxPrefetchChapters: value(
        'maxPrefetchChapters',
        _global.maxPrefetchChapters,
      ),
      requestTimeoutSeconds: value(
        'requestTimeoutSeconds',
        _global.requestTimeoutSeconds,
      ),
      contentRepairLimit: value(
        'contentRepairLimit',
        _global.contentRepairLimit,
      ),
      transportRetryLimit: value(
        'transportRetryLimit',
        _global.transportRetryLimit,
      ),
      dailyTokenLimit: value('dailyTokenLimit', _global.dailyTokenLimit),
      bookTokenLimit: value('bookTokenLimit', _global.bookTokenLimit),
      dailyRequestLimit: value('dailyRequestLimit', _global.dailyRequestLimit),
      bookRequestLimit: value('bookRequestLimit', _global.bookRequestLimit),
      dailyCostLimit: value<double?>(
        'dailyCostLimit',
        _global.dailyCostLimit,
        source: _global.dailyCostLimit == null ? 'builtin' : 'global',
      ),
      bookCostLimit: value<double?>(
        'bookCostLimit',
        _global.bookCostLimit,
        source: _global.bookCostLimit == null ? 'builtin' : 'global',
      ),
      markStyle: value('markStyle', _global.markStyle),
      sources: Map.unmodifiable(sources),
    );
  }

  AiResolvedPrompt resolvedPrompt(String bookId) {
    final overrides = _bookOverrides[bookId] ?? const <String, dynamic>{};
    return aiResolvePrompt(
      bookPrompt: overrides['behaviorPrompt'] as String?,
      globalPrompt: _global.behaviorPrompt,
    );
  }

  Future<void> saveGlobal(AiGlobalSettings value) async {
    _global = value;
    await _write(_globalKey, value.toJson());
    notifyListeners();
  }

  Future<void> saveDevice(AiDeviceSettings value) async {
    _device = value;
    await _write(_deviceKey, value.toJson());
    notifyListeners();
  }

  Future<void> upsertProvider(AiProviderProfile profile) async {
    _providers[profile.id] = profile;
    await _write('$_providerPrefix${profile.id}', profile.toJson());
    notifyListeners();
  }

  Future<void> deleteProvider(String id) async {
    _providers.remove(id);
    await _box?.delete('$_providerPrefix$id');
    final stale = _capabilities.values
        .where((capability) => capability.providerId == id)
        .map((capability) => capability.key)
        .toList();
    for (final key in stale) {
      _capabilities.remove(key);
      await _box?.delete('$_capabilityPrefix$key');
    }
    if (_global.providerId == id) {
      _global = _global.copyWith(providerId: null, modelId: null);
      await _write(_globalKey, _global.toJson());
    }
    notifyListeners();
  }

  Future<void> upsertRate(AiRateProfile rate) async {
    _rates[rate.id] = rate;
    await _write('$_ratePrefix${rate.id}', rate.toJson());
    notifyListeners();
  }

  Future<void> deleteRate(String id) async {
    _rates.remove(id);
    await _box?.delete('$_ratePrefix$id');
    notifyListeners();
  }

  Future<void> saveCapability(AiModelCapability capability) async {
    _capabilities[capability.key] = capability;
    await _write('$_capabilityPrefix${capability.key}', capability.toJson());
    notifyListeners();
  }

  Future<void> setBookOverride(String bookId, String key, Object? value) async {
    final map = _bookOverrides.putIfAbsent(bookId, () => <String, dynamic>{});
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
    if (map.isEmpty) {
      _bookOverrides.remove(bookId);
      await _box?.delete('$_bookPrefix$bookId');
    } else {
      await _write('$_bookPrefix$bookId', map);
    }
    notifyListeners();
  }

  Future<void> clearBookOverride(String bookId, String key) =>
      setBookOverride(bookId, key, null);

  Future<void> clearBookOverrides(String bookId) async {
    _bookOverrides.remove(bookId);
    await _box?.delete('$_bookPrefix$bookId');
    notifyListeners();
  }

  Future<void> setBehaviorPrompt(String bookId, String? value) =>
      setBookOverride(bookId, 'behaviorPrompt', value);

  Future<void> _write(String key, Object? value) async {
    final box = _box;
    if (box == null) return;
    final next = (_pendingWrite ?? Future<void>.value()).then((_) async {
      await box.put(key, value);
    });
    _pendingWrite = next;
    try {
      await next;
    } finally {}
  }

  static String _newCredentialRef() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static T? _coerce<T>(Object? raw) {
    if (raw is T) return raw;
    if (T == double && raw is num) return raw.toDouble() as T;
    if (T == int && raw is num) return raw.toInt() as T;
    if (T == AiDisplayMode) return AiDisplayMode.parse(raw) as T;
    return null;
  }

  static Map<String, dynamic>? _map(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.map((key, value) => MapEntry('$key', value));
    return null;
  }
}
