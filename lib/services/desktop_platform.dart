import 'package:screen_retriever/screen_retriever.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/desktop_login.dart';
import 'desktop_media.dart';
import 'app_log.dart';
import 'platform_channel.dart';

bool get isWindowsDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// On Windows an inactive window is still visible; it simply lacks input focus.
/// Only hidden/paused/detached windows should defer foreground video playback.
bool playbackAppIsActive(AppLifecycleState? state) =>
    state == null ||
    state == AppLifecycleState.resumed ||
    (isWindowsDesktop && state == AppLifecycleState.inactive);

/// 桌面窗口只是失焦时，是否仍算「在前台」。
///
/// Flutter 3.13 起桌面端有真正的生命周期：窗口失去焦点报 `inactive`，
/// 最小化报 `hidden` / `paused`。**失焦不是退到后台** —— 窗口还在、渲染还在
/// 跑；把它当后台会让听书跟随停止翻页（鼠标点一下别的窗口，页面就不跟了）。
///
/// 与 [playbackAppIsActive] 是同一件事的两处用法：那个管视频前台播放，这个
/// 管阅读页的跟随与高亮。平台范围比它宽一点，三个桌面平台都成立。
bool desktopInactiveStillVisible(AppLifecycleState state) =>
    state == AppLifecycleState.resumed ||
    ((!kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.macOS ||
                defaultTargetPlatform == TargetPlatform.linux)) &&
        state == AppLifecycleState.inactive);

class DesktopPlatform with WindowListener {
  DesktopPlatform._();
  static final instance = DesktopPlatform._();
  static final navigatorKey = GlobalKey<NavigatorState>();
  static final readerBrightness = ValueNotifier<double>(1);
  static final fullscreen = ValueNotifier<bool>(false);
  final _events = <String, StreamController<dynamic>>{};
  final _players = <int, _DesktopPlayer>{};
  final _tts = FlutterTts();
  SMTCWindows? _smtc;
  String? _utterance;
  int _nextId = 1000000;
  bool _closing = false;
  Future<void> Function()? beforeClose;
  bool _readerAwake = false;
  bool _playerAwake = false;
  String? _readerSession;
  Timer? _readerTimer;

  Stream<dynamic> events(String name) =>
      (_events[name] ??= StreamController<dynamic>.broadcast()).stream;
  void _emit(String name, dynamic event) => _events[name]?.add(event);

  Future<void> initialize() async {
    if (!isWindowsDesktop) return;
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    PlatformChannels.invoke = invoke;
    PlatformChannels.events = events;
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    final display = await screenRetriever.getPrimaryDisplay();
    final available = display.visibleSize ?? display.size;
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: Size(min(1280, available.width), min(800, available.height)),
        minimumSize: Size(
          min(800, available.width),
          min(440, available.height),
        ),
        center: true,
        title: '什锦铺',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    _tts.setCompletionHandler(() {
      final id = _utterance;
      if (id != null) {
        _utterance = null;
        _emit('fqapp/system_tts_events', {'type': 'done', 'id': id});
      }
    });
    _tts.setErrorHandler((dynamic _) {
      final id = _utterance;
      _utterance = null;
      _emit('fqapp/system_tts_events', {'type': 'error', 'id': id});
    });
    // Optional system media integration must not prevent reading or startup.
    try {
      await SMTCWindows.initialize();
      _smtc = SMTCWindows();
      _smtc!.buttonPressStream.listen((button) {
        final action = switch (button) {
          PressedButton.play => 'playPause',
          PressedButton.pause => 'playPause',
          PressedButton.next => 'next',
          PressedButton.previous => 'prev',
          PressedButton.stop => 'stop',
          _ => null,
        };
        if (action != null) {
          unawaited(
            PlatformChannels.notify(
              'fqapp/native_player',
              'onNotificationAction',
              {'action': action},
            ),
          );
        }
      });
      await _smtc!.disableSmtc();
    } catch (_) {
      _smtc = null;
    }
  }

  Widget videoSurface(int id, {Key? key}) {
    final host = _players[id];
    return host == null
        ? const SizedBox.expand()
        : Video(
            key: key,
            controller: host.video,
            controls: NoVideoControls,
            fit: BoxFit.fill,
            pauseUponEnteringBackgroundMode: false,
            resumeUponEnteringForegroundMode: false,
          );
  }

  Future<void> setFullscreen(bool value) async {
    await windowManager.setFullScreen(value);
    fullscreen.value = value;
  }

  @override
  void onWindowLeaveFullScreen() {
    fullscreen.value = false;
  }

  @override
  void onWindowEnterFullScreen() {
    fullscreen.value = true;
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      try {
        await beforeClose?.call();
      } catch (_) {}
      for (final host in _players.values.toList()) {
        await host.dispose();
      }
      _players.clear();
      _utterance = null;
      await _tts.stop();
      await _smtc?.disableSmtc();
      _readerTimer?.cancel();
      _readerAwake = _playerAwake = false;
      _updateAwake();
    } finally {
      await windowManager.destroy();
    }
  }

  Future<dynamic> invoke(
    String channel,
    String method,
    dynamic arguments,
  ) async {
    final args = arguments is Map ? arguments : const <dynamic, dynamic>{};
    switch (channel) {
      case 'fqapp/native_player':
        if (method == 'create') {
          final id = _nextId++;
          final host = _DesktopPlayer(
            id,
            (event) => _emit('fqapp/native_player/events', event),
          );
          _players[id] = host;
          unawaited(
            host.open(args['cdnUrl'] as String, args['keyHex'] as String),
          );
          return {'playerId': id};
        }
        if (method == 'setKeepScreenOn') {
          _playerAwake = args['on'] == true;
          _updateAwake();
          return null;
        }
        if (method == 'startListenForeground') {
          final smtc = _smtc;
          if (smtc == null) return null;
          await smtc.updateMetadata(
            MusicMetadata(
              title: args['title'] as String?,
              artist: args['episode'] as String?,
              // Windows 的「正在播放」卡片同样用作品封面（issue #123）；
              // SMTC 自己按 URL 拉图，取不到就保留应用图标。
              thumbnail: switch (args['coverUrl']) {
                final String url when url.isNotEmpty => url,
                _ => null,
              },
            ),
          );
          await smtc.setIsPrevEnabled(args['hasPrev'] == true);
          await smtc.setIsNextEnabled(args['hasNext'] == true);
          await smtc.updateTimeline(
            PlaybackTimeline(
              startTimeMs: 0,
              endTimeMs: (args['durationMs'] as num?)?.toInt() ?? 0,
              positionMs: (args['positionMs'] as num?)?.toInt() ?? 0,
              minSeekTimeMs: 0,
              maxSeekTimeMs: (args['durationMs'] as num?)?.toInt() ?? 0,
            ),
          );
          await smtc.setPlaybackStatus(
            args['playing'] == true
                ? PlaybackStatus.playing
                : PlaybackStatus.paused,
          );
          await smtc.enableSmtc();
          return null;
        }
        if (method == 'stopListenForeground') {
          await _smtc?.disableSmtc();
          return null;
        }
        final id = (args['id'] as num?)?.toInt();
        final host = _players[id];
        if (method == 'dispose') {
          _players.remove(id);
          await host?.dispose();
          return null;
        }
        if (host == null) {
          throw PlatformException(code: 'player_closed', message: '播放器已关闭');
        }
        await host.command(method, args);
        return null;
      case 'fqapp/library_backup':
        return _backup(method, args);
      case 'fqapp/local_books':
        if (method == 'pickBookFile') return _pickBook();
      case 'fqapp/downloads':
        if (method == 'saveText') {
          final path = await _save(
            args['fileName'] as String,
            Uint8List.fromList(utf8.encode(args['text'] as String)),
            ['txt'],
          );
          if (path == null) {
            throw PlatformException(code: 'cancelled', message: '已取消保存');
          }
          return {'path': path, 'public': true};
        }
      case 'fqapp/reader':
        return _reader(method, args);
      case 'fqapp/system_tts':
        return _speech(method, args);
      case 'fqapp/fanqie_account':
        if (method == 'login') {
          final context = navigatorKey.currentContext;
          if (context == null) {
            throw PlatformException(code: 'not_ready', message: '窗口尚未就绪');
          }
          return DesktopLogin.open(context);
        }
        if (method == 'cancelLogin') {
          DesktopLogin.cancel();
          return null;
        }
        if (method == 'clearSession') {
          await DesktopLogin.clearSession();
          return null;
        }
      case 'fqapp/eink-refresh':
        return false;
      case 'fqapp/volume-key':
        return null;
      case 'fqapp/fair_memory':
        return null;
    }
    throw MissingPluginException('$channel/$method');
  }

  Future<dynamic> _speech(String method, Map args) async {
    switch (method) {
      case 'engines':
        final voices = await _tts.getVoices;
        return {
          'defaultEngine': 'windows',
          'engines': [
            {'package': 'windows', 'label': 'Windows 默认语音'},
            if (voices is List)
              for (final voice in voices)
                if (voice is Map && voice['name'] is String)
                  {
                    'package': jsonEncode({
                      'name': voice['name'],
                      'locale': voice['locale'],
                    }),
                    'label': '${voice['name']} (${voice['locale']})',
                  },
          ],
        };
      case 'initialize':
        await _tts.stop();
        _utterance = null;
        final engine = args['engine'];
        if (engine is String && engine.startsWith('{')) {
          final voice = (jsonDecode(engine) as Map).cast<String, String>();
          await _tts.setVoice(voice);
        } else {
          await _tts.setLanguage('zh-CN');
        }
        await _tts.setSpeechRate(
          ((args['rate'] as num?)?.toDouble() ?? 1) * .5,
        );
        return 300;
      case 'speak':
        _utterance = args['id'] as String;
        final result = await _tts.speak(args['text'] as String);
        if (result == 0) {
          throw PlatformException(
            code: 'tts_failed',
            message: 'Windows 语音不可用，请安装中文语音',
          );
        }
        return null;
      case 'stop':
      case 'shutdown':
        _utterance = null;
        await _tts.stop();
        return null;
      case 'settings':
        await Process.run('explorer.exe', ['ms-settings:speech']);
        return null;
    }
    throw MissingPluginException(method);
  }

  Future<dynamic> _reader(String method, Map args) async {
    switch (method) {
      case 'start':
        _readerSession = args['session'] as String?;
        _readerTimer?.cancel();
        _readerTimer = Timer.periodic(
          const Duration(minutes: 1),
          (_) => _emit('fqapp/reader/events', _readerStatus()),
        );
        _setBrightness(args['brightness']);
        return _readerStatus();
      case 'setBrightness':
        _setBrightness(args['brightness']);
        return true;
      case 'keepScreenOn':
        _readerAwake = args['on'] == true;
        _updateAwake();
        return null;
      case 'stop':
      case 'suspend':
        _readerTimer?.cancel();
        readerBrightness.value = 1;
        _readerAwake = false;
        _updateAwake();
        return null;
      case 'setImmersive':
        return null;
      case 'pickFont':
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(label: '字体', extensions: ['ttf', 'otf', 'ttc']),
          ],
        );
        if (file == null) return null;
        if (await file.length() > 32 * 1024 * 1024) {
          throw PlatformException(code: 'file_size', message: '字体不能超过 32 MB');
        }
        final root = await getApplicationSupportDirectory();
        final fonts = await Directory(
          '${root.path}/fonts',
        ).create(recursive: true);
        final target = File(
          '${fonts.path}/${DateTime.now().microsecondsSinceEpoch}-${_safeName(file.name)}',
        );
        await File(file.path).copy(target.path);
        return {'path': target.path, 'name': file.name};
    }
    return null;
  }

  void _setBrightness(dynamic raw) {
    final value = raw is num ? raw.toDouble() : -1.0;
    readerBrightness.value = value < 0 ? 1 : value.clamp(.05, 1);
  }

  Map<String, dynamic> _readerStatus() => {
    'session': _readerSession,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'systemBrightness': 1.0,
  };
  void _updateAwake() {
    final call = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'SetThreadExecutionState',
        );
    call(0x80000000 | (_readerAwake || _playerAwake ? 3 : 0));
  }

  String _safeName(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  Future<String?> _save(
    String name,
    Uint8List bytes,
    List<String> extensions,
  ) async {
    final location = await getSaveLocation(
      suggestedName: _safeName(name),
      acceptedTypeGroups: [XTypeGroup(label: '文件', extensions: extensions)],
    );
    if (location == null) return null;
    await XFile.fromData(bytes, name: name).saveTo(location.path);
    return location.path;
  }

  Future<Directory> _captureDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/fanqie_capture').create(recursive: true);
  }

  bool _validPart(String name) =>
      RegExp(r'^part-[0-9]+-[a-fA-F0-9-]+\.json$').hasMatch(name);
  Future<dynamic> _backup(String method, Map args) async {
    switch (method) {
      case 'saveBackup':
        return await _save(args['name'] as String, args['bytes'] as Uint8List, [
              'json',
            ]) !=
            null;
      case 'openBackup':
        final selected = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(label: '备份文件', extensions: ['json']),
          ],
        );
        if (selected == null) return null;
        if (await selected.length() > 128 * 1024 * 1024) {
          throw PlatformException(code: 'file_size', message: '备份文件过大');
        }
        return selected.readAsBytes();
      case 'storeFanqieCapture':
        final root = await _captureDirectory();
        final temp = File('${root.path}/latest.tmp');
        await temp.writeAsBytes(args['bytes'] as Uint8List, flush: true);
        await temp.rename('${root.path}/latest.json');
        return true;
      case 'latestFanqieCapture':
        final root = await _captureDirectory();
        final file = File('${root.path}/latest.json');
        return await file.exists() ? file.readAsBytes() : null;
      case 'storeFanqieCapturePart':
        final root = await _captureDirectory();
        final random = Random.secure();
        final suffix = List.generate(
          12,
          (_) => random.nextInt(16).toRadixString(16),
        ).join();
        final name =
            'part-${DateTime.now().microsecondsSinceEpoch}-$suffix.json';
        await File(
          '${root.path}/$name',
        ).writeAsBytes(args['bytes'] as Uint8List, flush: true);
        return name;
      case 'readFanqieCapturePart':
        final name = args['name'] as String;
        if (!_validPart(name)) {
          throw PlatformException(code: 'invalid_part', message: '分卷名称无效');
        }
        final root = await _captureDirectory();
        final file = File('${root.path}/$name');
        return await file.exists() ? file.readAsBytes() : null;
      case 'exportFanqieCapture':
        final root = await _captureDirectory();
        final archive = Archive();
        final bytes = args['bytes'] as Uint8List;
        archive.addFile(ArchiveFile('capture.json', bytes.length, bytes));
        for (final name in (args['parts'] as List).cast<String>().toSet()) {
          if (!_validPart(name)) throw PlatformException(code: 'invalid_part');
          final bytes = await File('${root.path}/$name').readAsBytes();
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }
        return await _save(
              args['name'] as String,
              Uint8List.fromList(ZipEncoder().encode(archive)),
              ['zip'],
            ) !=
            null;
    }
    throw MissingPluginException(method);
  }

  Future<Map<String, dynamic>?> _pickBook() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '本地书籍', extensions: ['txt', 'epub']),
      ],
    );
    if (file == null) return null;
    if (await file.length() > 32 * 1024 * 1024) {
      throw PlatformException(code: 'file_size', message: '书籍不能超过 32 MB');
    }
    final bytes = await file.readAsBytes();
    return {
      'name': file.name,
      'bytes': bytes,
      'byteLength': bytes.length,
      if (file.name.toLowerCase().endsWith('.txt'))
        'text': decodeDesktopText(bytes),
    };
  }
}

String decodeDesktopText(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    final little = bytes[0] == 255;
    return String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2)
        little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
    ]);
  }
  try {
    return utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
  } on FormatException {
    final convert = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(
            Uint32,
            Uint32,
            Pointer<Uint8>,
            Int32,
            Pointer<Uint16>,
            Int32,
          ),
          int Function(int, int, Pointer<Uint8>, int, Pointer<Uint16>, int)
        >('MultiByteToWideChar');
    final input = calloc<Uint8>(bytes.length);
    input.asTypedList(bytes.length).setAll(0, bytes);
    Pointer<Uint16> output = nullptr;
    try {
      final length = convert(54936, 0, input, bytes.length, nullptr, 0);
      if (length == 0) throw const FormatException('无法识别 TXT 编码');
      output = calloc<Uint16>(length);
      if (convert(54936, 0, input, bytes.length, output, length) == 0) {
        throw const FormatException('无法读取 TXT');
      }
      return String.fromCharCodes(output.asTypedList(length));
    } finally {
      calloc.free(input);
      if (output != nullptr) calloc.free(output);
    }
  }
}

class _DesktopPlayer {
  _DesktopPlayer(this.id, this.emit) {
    video = VideoController(player);
    void event(String type, dynamic value) {
      if (!disposed) emit({'playerId': id, 'type': type, 'value': value});
    }

    subscriptions.addAll([
      player.stream.position.listen((v) => event('position', v.inMilliseconds)),
      player.stream.duration.listen((v) => event('duration', v.inMilliseconds)),
      player.stream.playing.listen((v) {
        AppLog.d('desktop-player', 'id=$id playing=$v');
        event('playing', v);
      }),
      player.stream.buffering.listen((v) => event('buffering', v)),
      player.stream.completed.listen((v) => event('completed', v)),
      player.stream.width.listen((_) => _size()),
      player.stream.height.listen((_) => _size()),
      player.stream.error.listen(
        (_) => event('error', {'message': '媒体播放失败，请重试或切换清晰度'}),
      ),
    ]);
    unawaited(
      video.waitUntilFirstFrameRendered.then((_) => event('firstFrame', true)),
    );
  }
  final int id;
  final void Function(Map<String, dynamic>) emit;
  final player = Player();
  late final VideoController video;
  final subscriptions = <StreamSubscription<dynamic>>[];
  final ready = Completer<void>();
  DesktopMedia? media;
  bool disposed = false;
  Future<void> open(String url, String key) async {
    ready.future.ignore();
    try {
      var playbackUrl = url;
      if (key.isNotEmpty) {
        final session = await DesktopMedia.open(url, key);
        if (disposed) {
          session.close();
          return;
        }
        media = session;
        playbackUrl = session.url;
      }
      // Plain audio/video follows the original URI player contract. Some
      // public audio origins return 200 only and must not require CENC Range I/O.
      if (disposed) return;
      await player.open(Media(playbackUrl), play: false);
      AppLog.d('desktop-player', 'id=$id opened paused');
      if (disposed) return;
      ready.complete();
      emit({'playerId': id, 'type': 'created', 'value': id});
      _size();
    } catch (_) {
      if (!ready.isCompleted) ready.completeError(StateError('无法打开媒体'));
      if (!disposed) {
        emit({
          'playerId': id,
          'type': 'error',
          'value': {'message': '媒体加载失败，请检查网络或重试'},
        });
      }
      media?.close();
    }
  }

  void _size() {
    if (!disposed) {
      emit({
        'playerId': id,
        'type': 'videoSize',
        'width': player.state.width ?? 0,
        'height': player.state.height ?? 0,
        'rotationCorrection': 0,
      });
    }
  }

  Future<void> command(String method, Map args) async {
    await ready.future;
    if (disposed) return;
    AppLog.d('desktop-player', 'id=$id command=$method');
    switch (method) {
      case 'play':
        await player.play();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': true});
      case 'pause':
        await player.pause();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': false});
      case 'seek':
        await player.seek(
          Duration(milliseconds: (args['positionMs'] as num).toInt()),
        );
      case 'setRate':
        await player.setRate((args['rate'] as num).toDouble());
      case 'setVolume':
        await player.setVolume(
          (args['volume'] as num).toDouble().clamp(0, 1) * 100,
        );
      default:
        throw MissingPluginException(method);
    }
  }

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
    media?.close();
  }
}
