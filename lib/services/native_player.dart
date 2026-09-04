import 'dart:async';

import 'package:flutter/services.dart';

/// Flutter-side wrapper of the native ExoPlayer host (NativePlayerPlugin).
///
/// [create] takes the encrypted CDN URL plus the 16-byte AES key (hex); the
/// C crypto core decrypts CENC on the fly and ExoPlayer renders the
/// plaintext. Playback state is pushed over an EventChannel.
class NativePlayer {
  static const _channel = MethodChannel('fqapp/native_player');
  static const _events = EventChannel('fqapp/native_player/events');

  static StreamSubscription? _globalEventSub;
  static final Map<int, NativePlayer> _instances = {};

  static void _ensureGlobalListener() {
    if (_globalEventSub != null) return;
    _globalEventSub = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final playerId = event['playerId'] as int?;
      if (playerId == null) return;
      _instances[playerId]?._handleEvent(event);
    });
  }

  int? _playerId;
  int? _textureId;
  bool _disposed = false;

  int? get textureId => _textureId;
  bool get isCreated => _textureId != null;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _completed = false;
  bool _buffering = false;
  bool _firstFrameRendered = false;
  int _videoWidth = 0;
  int _videoHeight = 0;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get completed => _completed;
  bool get buffering => _buffering;
  bool get firstFrameRendered => _firstFrameRendered;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;

  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _firstFrameCtrl = StreamController<bool>.broadcast();

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;
  Stream<bool> get firstFrameStream => _firstFrameCtrl.stream;

  // ─── 生命周期 ──────────────────────────────────────────────────────────

  final _createdCompleter = Completer<int>();

  Future<int> create(String cdnUrl, String keyHex) async {
    _ensureGlobalListener();
    final result = await _channel.invokeMapMethod<String, dynamic>('create', {
      'cdnUrl': cdnUrl,
      'keyHex': keyHex,
    });
    _playerId = result!['playerId'] as int;
    _instances[_playerId!] = this;
    // textureId 通过 EventChannel 异步推送
    _textureId = await _createdCompleter.future;
    return _textureId!;
  }

  Future<void> play() async {
    if (_disposed) return;
    _channel.invokeMethod('play', {'id': _playerId});
  }

  Future<void> pause() async {
    if (_disposed) return;
    _channel.invokeMethod('pause', {'id': _playerId});
  }

  Future<void> seek(Duration position) async {
    if (_disposed) return;
    _channel.invokeMethod('seek', {
      'id': _playerId,
      'positionMs': position.inMilliseconds,
    });
  }

  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    _channel.invokeMethod('setVolume', {
      'id': _playerId,
      'volume': volume,
    });
  }

  Future<void> setRate(double rate) async {
    if (_disposed) return;
    _channel.invokeMethod('setRate', {
      'id': _playerId,
      'rate': rate,
    });
  }

  static Future<void> setKeepScreenOn(bool on) async {
    _channel.invokeMethod('setKeepScreenOn', {'on': on});
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_playerId != null) _instances.remove(_playerId);
    try {
      await _channel.invokeMethod('dispose', {'id': _playerId});
    } catch (_) {}
    _positionCtrl.close();
    _durationCtrl.close();
    _playingCtrl.close();
    _completedCtrl.close();
    _bufferingCtrl.close();
    _firstFrameCtrl.close();
  }

  // ─── 事件处理 ──────────────────────────────────────────────────────────

  void _handleEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'created':
        final textureId = event['value'] as int;
        if (!_createdCompleter.isCompleted) {
          _createdCompleter.complete(textureId);
        }
      case 'error':
        if (!_createdCompleter.isCompleted) {
          _createdCompleter.completeError(
            Exception(event['value'] as String? ?? 'unknown error'),
          );
        }
      case 'position':
        if (_disposed) return;
        final ms = event['value'] as int;
        _position = Duration(milliseconds: ms);
        _positionCtrl.add(_position);
      case 'duration':
        if (_disposed) return;
        final ms = event['value'] as int;
        _duration = Duration(milliseconds: ms);
        _durationCtrl.add(_duration);
      case 'playing':
        if (_disposed) return;
        _playing = event['value'] as bool;
        _playingCtrl.add(_playing);
      case 'completed':
        if (_disposed) return;
        _completed = event['value'] as bool;
        _completedCtrl.add(_completed);
      case 'buffering':
        if (_disposed) return;
        _buffering = event['value'] as bool;
        _bufferingCtrl.add(_buffering);
      case 'firstFrame':
        if (_disposed) return;
        _firstFrameRendered = true;
        _firstFrameCtrl.add(true);
      case 'videoSize':
        if (_disposed) return;
        _videoWidth = event['width'] as int;
        _videoHeight = event['height'] as int;
    }
  }
}
