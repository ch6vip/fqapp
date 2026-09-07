import 'dart:async';

import 'package:flutter/services.dart';

class NativePlaybackException implements Exception {
  final String message;
  final int? errorCode;
  final int? httpStatusCode;

  const NativePlaybackException(
    this.message, {
    this.errorCode,
    this.httpStatusCode,
  });

  factory NativePlaybackException.fromEvent(Object? value) {
    if (value is Map) {
      return NativePlaybackException(
        value['message'] is String
            ? value['message'] as String
            : 'Player error',
        errorCode: value['errorCode'] is int ? value['errorCode'] as int : null,
        httpStatusCode: value['httpStatusCode'] is int
            ? value['httpStatusCode'] as int
            : null,
      );
    }
    // Creation/probe errors and older hosts still send a plain string.
    return NativePlaybackException(value is String ? value : 'Player error');
  }

  @override
  String toString() => 'NativePlaybackException: $message';
}

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
  bool _creationFailed = false;
  Future<int>? _createFuture;
  Future<void>? _disposeFuture;
  Future<void>? _nativeRelease;
  int _seekGeneration = 0;
  int _playWhenReadyGeneration = 0;

  int? get textureId => _textureId;
  bool get isCreated => _textureId != null && !_disposed;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _playWhenReady = false;
  bool _completed = false;
  bool _buffering = false;
  bool _firstFrameRendered = false;
  int _videoWidth = 0;
  int _videoHeight = 0;
  int _videoRotationCorrection = 0;
  Object? _lastError;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;

  /// Playback intent stays true while ExoPlayer is buffering or suppressed.
  bool get playWhenReady => _playWhenReady;
  bool get completed => _completed;
  bool get buffering => _buffering;
  bool get firstFrameRendered => _firstFrameRendered;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;

  /// Clockwise rotation not applied by the native texture backend.
  int get videoRotationCorrection => _videoRotationCorrection;
  Object? get lastError => _lastError;

  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _playWhenReadyCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _firstFrameCtrl = StreamController<bool>.broadcast();
  final _videoSizeCtrl = StreamController<Size>.broadcast();
  final _errorCtrl = StreamController<Object>.broadcast();

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<bool> get playWhenReadyStream => _playWhenReadyCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;
  Stream<bool> get firstFrameStream => _firstFrameCtrl.stream;
  Stream<Size> get videoSizeStream => _videoSizeCtrl.stream;
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
    // Disposal or an early native error can finish this future before the
    // method reply supplies an id. Observe errors now; the await below still
    // propagates them to create's caller.
    _createdCompleter.future.ignore();
    try {
      final reply = _channel
          .invokeMapMethod<String, dynamic>('create', {
            'cdnUrl': cdnUrl,
            'keyHex': keyHex,
          })
          .then((result) async {
            final rawPlayerId = result?['playerId'];
            if (rawPlayerId is! num) {
              throw StateError('Native player returned no playerId');
            }
            final playerId = _playerId = rawPlayerId.toInt();
            // Keep observing the original reply even after timeout. Otherwise
            // a late native allocation would never be released.
            if (_disposed || _creationFailed) {
              await _releaseNative();
              throw StateError('NativePlayer was disposed during creation');
            }
            return playerId;
          });
      final playerId = await reply.timeout(_methodTimeout);
      if (_disposed) {
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
      _creationFailed = true;
      await _releaseNative();
      rethrow;
    }
  }

  Future<void> play() => _setPlayWhenReady(true);
  Future<void> pause() => _setPlayWhenReady(false);

  Future<void> _setPlayWhenReady(bool value) async {
    if (_disposed) return;
    final generation = ++_playWhenReadyGeneration;
    final previous = _playWhenReady;
    _updatePlayWhenReady(value);
    try {
      await _invoke(value ? 'play' : 'pause');
    } catch (_) {
      if (!_disposed && generation == _playWhenReadyGeneration) {
        _updatePlayWhenReady(previous);
      }
      rethrow;
    }
  }

  void _updatePlayWhenReady(bool value) {
    if (_playWhenReady == value) return;
    _playWhenReady = value;
    _playWhenReadyCtrl.add(value);
  }

  Future<void> seek(Duration position) async {
    final generation = ++_seekGeneration;
    await _invoke('seek', {'positionMs': position.inMilliseconds});
    if (_disposed || generation != _seekGeneration) return;
    // ExoPlayer acknowledges seek before its next position tick. Preserve the
    // accepted position for immediate exit/reentry and during initial buffering.
    _position = position;
    _completed = false;
    _positionCtrl.add(position);
  }

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

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    if (_createFuture != null && !_createdCompleter.isCompleted) {
      _createdCompleter.completeError(StateError('NativePlayer disposed'));
    }
    await _releaseNative();
    await Future.wait<void>([
      _positionCtrl.close(),
      _durationCtrl.close(),
      _playingCtrl.close(),
      _playWhenReadyCtrl.close(),
      _completedCtrl.close(),
      _bufferingCtrl.close(),
      _firstFrameCtrl.close(),
      _videoSizeCtrl.close(),
      _errorCtrl.close(),
    ]);
  }

  Future<void> _releaseNative() {
    final playerId = _playerId;
    if (playerId == null) return Future<void>.value();
    return _nativeRelease ??= () {
      _instances.remove(playerId);
      _retire(playerId);
      return _disposeNative(playerId);
    }();
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
        final error = NativePlaybackException.fromEvent(event['value']);
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
      case 'playWhenReady':
        final value = event['value'];
        if (value is! bool) return;
        ++_playWhenReadyGeneration;
        _updatePlayWhenReady(value);
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
          final rotation = event['rotationCorrection'];
          _videoRotationCorrection =
              rotation is num && const [90, 180, 270].contains(rotation)
              ? rotation.toInt()
              : 0;
          _videoSizeCtrl.add(Size(width.toDouble(), height.toDouble()));
        }
    }
  }
}
