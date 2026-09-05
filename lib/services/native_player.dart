import 'dart:async';

import 'package:flutter/services.dart';

/// Flutter-side wrapper of the native ExoPlayer host.
class NativePlayer {
  static const _channel = MethodChannel('fqapp/native_player');
  static const _events = EventChannel('fqapp/native_player/events');
  static const _methodTimeout = Duration(seconds: 10);
  static const _createTimeout = Duration(seconds: 25);

  static StreamSubscription<dynamic>? _globalEventSub;
  static final Map<int, NativePlayer> _instances = {};
  static final Map<int, List<dynamic>> _pendingEvents = {};
  static final Map<int, Timer> _pendingExpiry = {};
  static final Map<int, Timer> _retiredExpiry = {};

  static void _ensureGlobalListener() {
    if (_globalEventSub != null) return;
    late final StreamSubscription<dynamic> subscription;
    subscription = _events.receiveBroadcastStream().listen(
      _dispatchEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_globalEventSub, subscription)) {
          _globalEventSub = null;
        }
        for (final player in _instances.values.toList(growable: false)) {
          player._handleChannelError(error, stackTrace);
        }
        _clearPendingEvents();
      },
      onDone: () {
        if (identical(_globalEventSub, subscription)) {
          _globalEventSub = null;
        }
        final error = StateError('Native player event channel closed');
        for (final player in _instances.values.toList(growable: false)) {
          player._handleChannelError(error, StackTrace.current);
        }
        _clearPendingEvents();
      },
      cancelOnError: true,
    );
    _globalEventSub = subscription;
  }

  static void _dispatchEvent(dynamic event) {
    if (event is! Map) return;
    final rawPlayerId = event['playerId'];
    if (rawPlayerId is! num) return;
    final playerId = rawPlayerId.toInt();
    if (_retiredExpiry.containsKey(playerId)) return;
    final instance = _instances[playerId];
    if (instance != null) {
      instance._handleEvent(event);
      return;
    }

    final pending = _pendingEvents.putIfAbsent(playerId, () => []);
    if (pending.length < 16) pending.add(event);
    _pendingExpiry[playerId]?.cancel();
    _pendingExpiry[playerId] = Timer(const Duration(seconds: 15), () {
      _pendingEvents.remove(playerId);
      _pendingExpiry.remove(playerId);
    });
  }

  static void _clearPendingEvents() {
    _pendingEvents.clear();
    for (final timer in _pendingExpiry.values) {
      timer.cancel();
    }
    _pendingExpiry.clear();
  }

  static void _retire(int playerId) {
    _pendingEvents.remove(playerId);
    _pendingExpiry.remove(playerId)?.cancel();
    _retiredExpiry.remove(playerId)?.cancel();
    _retiredExpiry[playerId] = Timer(const Duration(seconds: 30), () {
      _retiredExpiry.remove(playerId);
    });
  }

  int? _playerId;
  int? _textureId;
  bool _disposed = false;
  Future<int>? _createFuture;

  int? get textureId => _textureId;
  bool get isCreated => _textureId != null && !_disposed;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _completed = false;
  bool _buffering = false;
  bool _firstFrameRendered = false;
  int _videoWidth = 0;
  int _videoHeight = 0;
  Object? _lastError;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get completed => _completed;
  bool get buffering => _buffering;
  bool get firstFrameRendered => _firstFrameRendered;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;
  Object? get lastError => _lastError;

  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _firstFrameCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<Object>.broadcast();

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;
  Stream<bool> get firstFrameStream => _firstFrameCtrl.stream;
  Stream<Object> get errorStream => _errorCtrl.stream;

  final _createdCompleter = Completer<int>();

  Future<int> create(String cdnUrl, String keyHex) {
    if (_disposed) {
      return Future<int>.error(StateError('NativePlayer is disposed'));
    }
    return _createFuture ??= _create(cdnUrl, keyHex);
  }

  Future<int> _create(String cdnUrl, String keyHex) async {
    _ensureGlobalListener();
    try {
      final result = await _channel
          .invokeMapMethod<String, dynamic>('create', {
            'cdnUrl': cdnUrl,
            'keyHex': keyHex,
          })
          .timeout(_methodTimeout);
      final rawPlayerId = result?['playerId'];
      if (rawPlayerId is! num) {
        throw StateError('Native player returned no playerId');
      }
      final playerId = rawPlayerId.toInt();
      _playerId = playerId;
      if (_disposed) {
        _retire(playerId);
        await _disposeNative(playerId);
        throw StateError('NativePlayer was disposed during creation');
      }

      _instances[playerId] = this;
      _pendingExpiry.remove(playerId)?.cancel();
      final pending = _pendingEvents.remove(playerId);
      if (pending != null) {
        for (final event in pending) {
          _handleEvent(event);
        }
      }

      _textureId = await _createdCompleter.future.timeout(_createTimeout);
      if (_disposed) {
        throw StateError('NativePlayer was disposed during creation');
      }
      return _textureId!;
    } catch (_) {
      final playerId = _playerId;
      if (playerId != null) {
        _instances.remove(playerId);
        _retire(playerId);
        await _disposeNative(playerId);
      }
      rethrow;
    }
  }

  Future<void> play() => _invoke('play');
  Future<void> pause() => _invoke('pause');

  Future<void> seek(Duration position) =>
      _invoke('seek', {'positionMs': position.inMilliseconds});

  Future<void> setVolume(double volume) =>
      _invoke('setVolume', {'volume': volume});

  Future<void> setRate(double rate) => _invoke('setRate', {'rate': rate});

  Future<void> _invoke(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (_disposed) return;
    final playerId = _playerId;
    if (playerId == null) throw StateError('NativePlayer is not created');
    await _channel
        .invokeMethod<void>(method, {'id': playerId, ...arguments})
        .timeout(_methodTimeout);
  }

  static Future<void> setKeepScreenOn(bool on) async {
    await _channel
        .invokeMethod<void>('setKeepScreenOn', {'on': on})
        .timeout(_methodTimeout);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final playerId = _playerId;
    if (playerId != null) {
      _instances.remove(playerId);
      _retire(playerId);
      await _disposeNative(playerId);
    }
    if (_createFuture != null && !_createdCompleter.isCompleted) {
      _createdCompleter.completeError(StateError('NativePlayer disposed'));
    }
    await Future.wait<void>([
      _positionCtrl.close(),
      _durationCtrl.close(),
      _playingCtrl.close(),
      _completedCtrl.close(),
      _bufferingCtrl.close(),
      _firstFrameCtrl.close(),
      _errorCtrl.close(),
    ]);
  }

  static Future<void> _disposeNative(int playerId) async {
    try {
      await _channel
          .invokeMethod<void>('dispose', {'id': playerId})
          .timeout(_methodTimeout);
    } catch (_) {
      // Local state is already retired; native teardown is best effort when
      // the engine/channel itself is shutting down.
    }
  }

  void _handleChannelError(Object error, StackTrace stackTrace) {
    if (_disposed) return;
    _lastError = error;
    if (!_createdCompleter.isCompleted) {
      _createdCompleter.completeError(error, stackTrace);
    }
    if (!_errorCtrl.isClosed) _errorCtrl.add(error);
  }

  void _handleEvent(dynamic event) {
    if (_disposed || event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'created':
        final value = event['value'];
        if (value is num && !_createdCompleter.isCompleted) {
          _createdCompleter.complete(value.toInt());
        }
      case 'error':
        final error = StateError('${event['value'] ?? 'unknown player error'}');
        _lastError = error;
        if (!_createdCompleter.isCompleted) {
          _createdCompleter.completeError(error);
        }
        if (!_errorCtrl.isClosed) _errorCtrl.add(error);
      case 'position':
        final value = event['value'];
        if (value is! num) return;
        _position = Duration(milliseconds: value.toInt());
        _positionCtrl.add(_position);
      case 'duration':
        final value = event['value'];
        if (value is! num) return;
        _duration = Duration(milliseconds: value.toInt());
        _durationCtrl.add(_duration);
      case 'playing':
        final value = event['value'];
        if (value is! bool) return;
        _playing = value;
        _playingCtrl.add(_playing);
      case 'completed':
        final value = event['value'];
        if (value is! bool) return;
        _completed = value;
        _completedCtrl.add(_completed);
      case 'buffering':
        final value = event['value'];
        if (value is! bool) return;
        _buffering = value;
        _bufferingCtrl.add(_buffering);
      case 'firstFrame':
        _firstFrameRendered = true;
        _firstFrameCtrl.add(true);
      case 'videoSize':
        final width = event['width'];
        final height = event['height'];
        if (width is num && height is num) {
          _videoWidth = width.toInt();
          _videoHeight = height.toInt();
        }
    }
  }
}
