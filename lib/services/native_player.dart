import 'platform_channel.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'app_log.dart';
import 'player_preferences.dart';

// Codec metadata only: never log the whole platform payload or exception text.
final _decoderToken = RegExp(r'^[A-Za-z0-9_.+/-]{1,160}$');

Map<String, Object> _safeDecoderDiagnostics(Object? value) {
  if (value is! Map) return const {};
  String? token(Object? raw) =>
      raw is String && _decoderToken.hasMatch(raw) ? raw : null;
  return {
    for (final key in ['name', 'mimeType', 'diagnosticInfo'])
      if (token(value[key]) case final String safe) key: safe,
    if (value['fallbackDecoders'] case final List fallbacks)
      'fallbackDecoders': [
        for (final name in fallbacks.take(8))
          if (token(name) case final String safe) safe,
      ],
  };
}

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
  static const _channel = AppMethodChannel('fqapp/native_player');
  static const _events = AppEventChannel('fqapp/native_player/events');
  static const _methodTimeout = Duration(seconds: 10);
  static const _createTimeout = Duration(seconds: 25);

  /// The app's listening owner coordinates audio with video playback. The
  /// generation below cancels a pending play if another player pauses it.
  static Future<void> Function(NativePlayer)? beforePlay;

  static Future<void> pauseOthers([NativePlayer? active]) async {
    for (final player in _instances.values.toList(growable: false)) {
      if (!identical(player, active) && player._playWhenReady) {
        await player.pause();
      }
    }
  }

  static void Function(String action)? _onRemoteAction;
  static VoidCallback? _onBecomingNoisy;

  static void setRemoteCommandHandler({
    void Function(String action)? onAction,
    VoidCallback? onBecomingNoisy,
  }) {
    _onRemoteAction = onAction;
    _onBecomingNoisy = onBecomingNoisy;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static void clearRemoteCommandHandler() {
    _onRemoteAction = null;
    _onBecomingNoisy = null;
  }

  static StreamSubscription<dynamic>? _globalEventSub;
  static final Map<int, NativePlayer> _instances = {};
  static final Map<int, List<dynamic>> _pendingEvents = {};
  static final Map<int, Timer> _pendingExpiry = {};
  static final Map<int, Timer> _retiredExpiry = {};

  static void _ensureGlobalListener() {
    _channel.setMethodCallHandler(_handleMethodCall);
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

  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onNotificationAction':
        final raw = call.arguments;
        final action = raw is Map
            ? raw['action'] as String?
            : raw is String
            ? raw
            : null;
        if (action != null) {
          _onRemoteAction?.call(action);
        }
      case 'onAudioBecomingNoisy':
        _onBecomingNoisy?.call();
    }
    return null;
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
  int _appliedSeekGeneration = 0;
  int _playWhenReadyGeneration = 0;

  int? get textureId => _textureId;
  int? get playerId => _playerId;
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
  final _textureIdCtrl = StreamController<int>.broadcast();
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

  /// Fires when native swaps the output surface (software-decoder fallback
  /// moves from SurfaceProducer to SurfaceTexture in #2) and the Texture
  /// widget must rebuild with the new id. The old id stops producing frames.
  Stream<int> get textureIdStream => _textureIdCtrl.stream;

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
            // 解码器偏好必须是**已解析的值**，不能在这里 await 读盘：create 位于
            // 起播的关键路径上，等 SharedPreferences 会让没有初始化插件的测试
            // （以及冷启动）一直挂住。偏好由 `DecoderPreferenceCache` 在启动和
            // 设置变更时维护。
            'videoDecoder': DecoderPreferenceCache.current.name,
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

      await _createdCompleter.future.timeout(_createTimeout);
      if (_disposed) {
        throw StateError('NativePlayer was disposed during creation');
      }
      // _textureId is maintained by the event handler, not by the completer's
      // value: a textureChanged that arrived with the pending replay (native
      // posts created → decoderInitialized → textureChanged in order) already
      // superseded the created id, and assigning the completer's stale value
      // here would resurrect the dead texture.
      if (_textureId == null) {
        throw StateError('Native player returned no texture id');
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
      if (value) {
        await beforePlay?.call(this);
        if (_disposed || generation != _playWhenReadyGeneration) return;
      }
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
    // Record every natively acknowledged seek, not just the newest call. If a
    // later overlapping seek fails, the position ExoPlayer actually accepted
    // must survive instead of reverting to the stale pre-seek value.
    if (_disposed || generation <= _appliedSeekGeneration) return;
    _appliedSeekGeneration = generation;
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

  /// [positionMs] / [durationMs] / [speed] 喂给系统媒体卡片：位置 + 倍速由系统外推，
  /// 总时长决定卡片两侧的时间。缺省 0/0/1 时卡片显示 00:00，所以调用方要尽量给真实值。
  ///
  /// [coverUrl] 是当前在读/在听内容的封面地址。官方（`dn2/i.java`
  /// `PlayNotificationImpl`）把它下载成 Bitmap 后同时写进通知的
  /// `setLargeIcon` 与媒体会话的 `METADATA_KEY_ALBUM_ART`，系统媒体卡片、
  /// 锁屏与通知左上角显示的都是它；拿不到或下载失败时退回应用图标。
  static Future<void> startListenForeground({
    required String title,
    required String episode,
    String coverUrl = '',
    bool playing = true,
    bool hasPrev = true,
    bool hasNext = true,
    int positionMs = 0,
    int durationMs = 0,
    double speed = 1,
  }) async {
    try {
      // No .timeout() here on purpose: the call is best-effort and the
      // plugin replies synchronously, while Future.timeout() leaves a
      // pending 10s timer that breaks widget tests under FakeAsync when
      // the fire-and-forget call is still in flight at test end.
      await _channel.invokeMethod<void>('startListenForeground', {
        'title': title,
        'episode': episode,
        'coverUrl': coverUrl,
        'playing': playing,
        'hasPrev': hasPrev,
        'hasNext': hasNext,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'speed': speed,
      });
    } catch (_) {
      // Best effort when channel/platform is unavailable or testing.
    }
  }

  static Future<void> stopListenForeground() async {
    try {
      // Same as startListenForeground: no .timeout(), see above.
      await _channel.invokeMethod<void>('stopListenForeground');
    } catch (_) {
      // Best effort when channel/platform is unavailable or testing.
    }
  }

  /// 悬浮窗权限：Android 需要用户在系统设置里允许“显示在其他应用的上层”。
  static Future<bool> canDrawOverlays() async {
    try {
      final granted = await _channel.invokeMethod<bool>('canDrawOverlays');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统悬浮窗权限设置页。返回 false 表示当前平台不需要或无法打开。
  static Future<bool> requestOverlayPermission() async {
    try {
      final opened = await _channel.invokeMethod<bool>('requestOverlayPermission');
      return opened ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 开始悬浮窗播放：原生侧启动悬浮窗服务，surface 就绪后把解码画面从
  /// Flutter 纹理换到悬浮窗；悬浮窗先隐藏，等 Dart 确认切后台后再显示
  /// （直接在后台启动前台服务会被 Android 12+ 拒绝）。
  /// 失败时抛错（焦点被占 / 播放器不存在 / 服务启动失败），调用方据此
  /// 决定不进悬浮、改走切后台暂停。
  static Future<void> startFloating({
    required int playerId,
    required String title,
    required String episode,
    bool playing = true,
    bool hasPrev = true,
    bool hasNext = true,
    int positionMs = 0,
    int durationMs = 0,
    double speed = 1,
    int videoWidth = 0,
    int videoHeight = 0,
  }) async {
    await _channel
        .invokeMethod<void>('startFloating', {
          'playerId': playerId,
          'title': title,
          'episode': episode,
          'playing': playing,
          'hasPrev': hasPrev,
          'hasNext': hasNext,
          'positionMs': positionMs,
          'durationMs': durationMs,
          'speed': speed,
          'videoWidth': videoWidth,
          'videoHeight': videoHeight,
        })
        .timeout(_methodTimeout);
  }

  /// 确认切后台，显示悬浮窗。
  static Future<void> showFloating() async {
    try {
      await _channel.invokeMethod<void>('showFloating').timeout(_methodTimeout);
    } catch (_) {
      // Best effort when channel/platform is unavailable or testing.
    }
  }

  /// 刷新悬浮窗通知 / 控制条的播放状态（切集、播放暂停时调用）。
  static Future<void> updateFloating({
    String? title,
    String? episode,
    bool? playing,
    bool? hasPrev,
    bool? hasNext,
    int? positionMs,
    int? durationMs,
    double? speed,
  }) async {
    try {
      await _channel
          .invokeMethod<void>('updateFloating', {
            // 全量传：Kotlin 侧 call.argument 对缺 key 与 null 值都返回
            // null，行为相同；collection-if 会被 use_null_aware_elements
            // lint 判 info，CI 把 info 当失败。
            'title': title,
            'episode': episode,
            'playing': playing,
            'hasPrev': hasPrev,
            'hasNext': hasNext,
            'positionMs': positionMs,
            'durationMs': durationMs,
            'speed': speed,
          })
          .timeout(_methodTimeout);
    } catch (_) {
      // Best effort when channel/platform is unavailable or testing.
    }
  }

  /// 停悬浮：画面回 Flutter 纹理，停悬浮窗服务。
  static Future<void> stopFloating() async {
    try {
      await _channel.invokeMethod<void>('stopFloating').timeout(_methodTimeout);
    } catch (_) {
      // Best effort when channel/platform is unavailable or testing.
    }
  }

  /// 后台自动切集：新播放器接手悬浮窗（服务不重启，避免后台启动限制）。
  /// 接手失败时抛错，调用方只能接受悬浮窗黑屏（旧播放器已销毁）。
  static Future<void> swapFloatingPlayer({required int playerId}) async {
    await _channel
        .invokeMethod<void>('swapFloatingPlayer', {'playerId': playerId})
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
      _textureIdCtrl.close(),
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
        if (value is num) {
          _textureId = value.toInt();
          if (!_createdCompleter.isCompleted) {
            _createdCompleter.complete(value.toInt());
          }
        }
      case 'textureChanged':
        final value = event['value'];
        if (value is num) {
          _textureId = value.toInt();
          // The swap moves decoder output to a legacy SurfaceTexture, which
          // applies the format rotation itself (#36). A videoSize event that
          // landed before the swap still carries the pre-swap correction
          // (e.g. 90 for a rotated source); keeping it would rotate the
          // already-rotated texture a second time, stretching a landscape
          // picture up to fullscreen. Reset it and re-emit the geometry so
          // size/rotation subscribers refresh (the feed reads rotation from
          // its own notifier, not from the player, on rebuild).
          _videoRotationCorrection = 0;
          if (!_videoSizeCtrl.isClosed) {
            _videoSizeCtrl.add(
              Size(_videoWidth.toDouble(), _videoHeight.toDouble()),
            );
          }
          if (!_textureIdCtrl.isClosed) _textureIdCtrl.add(_textureId!);
        }
      case 'error':
        final error = NativePlaybackException.fromEvent(event['value']);
        final value = event['value'];
        AppLog.d(
          'player-decoder',
          jsonEncode({
            'playerId': _playerId,
            'phase': 'failed',
            'errorCode': error.errorCode,
            'httpStatusCode': error.httpStatusCode,
            ..._safeDecoderDiagnostics(value is Map ? value['decoder'] : null),
          }),
        );
        _lastError = error;
        if (!_createdCompleter.isCompleted) {
          _createdCompleter.completeError(error);
        }
        if (!_errorCtrl.isClosed) _errorCtrl.add(error);
      case 'decoderInitialized':
        AppLog.d(
          'player-decoder',
          jsonEncode({
            'playerId': _playerId,
            'phase': 'initialized',
            ..._safeDecoderDiagnostics(event['value']),
          }),
        );
      case 'position':
        final value = event['value'];
        if (value is! num) return;
        _position = Duration(milliseconds: value.toInt());
        _positionCtrl.add(_position);
      case 'duration':
        final value = event['value'];
        if (value is! num) return;
        final ms = value.toInt();
        // ExoPlayer 未知时长回的是 C.TIME_UNSET（一个巨大负数），当「还不知道」处理，
        // 别把它当成真实时长往下传。
        if (ms <= 0) return;
        _duration = Duration(milliseconds: ms);
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
          // 诊断：issue #11 竖版源在换档后被塞进横向盒子导致拉伸。这里把
          // 原生上报的原始字段全量抛出，用来区分「尺寸本身是编码尺寸」还是
          // 「布局/旋转约定不一致」。
          AppLog.d(
            'video-size',
            'w=$_videoWidth h=$_videoHeight rawRotation=$rotation '
                'applied=$_videoRotationCorrection '
                'formatRotation=${event['formatRotation']} '
                'producerHandles=${event['handlesCropAndRotation']}',
          );
          _videoSizeCtrl.add(Size(width.toDouble(), height.toDouble()));
        }
    }
  }
}
