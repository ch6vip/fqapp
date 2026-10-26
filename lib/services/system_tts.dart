import 'platform_channel.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../models/text_replacement_rule.dart';
import 'text_replacement_engine.dart';
import 'text_replacement_store.dart';
import 'api_client.dart';
import 'audio_preferences.dart';
import 'backend_transport.dart';
import 'chapter_cache_store.dart';
import 'chapter_text_formatter.dart';
import 'listening_session.dart';
import 'narration_sentence.dart';
import 'native_player.dart';

class SystemTtsEngine {
  const SystemTtsEngine(this.package, this.label);
  final String package;
  final String label;
}

class SystemTts {
  static const _channel = AppMethodChannel('fqapp/system_tts');
  static const _events = AppEventChannel('fqapp/system_tts_events');
  static final events = _events.receiveBroadcastStream();

  static Future<T?> _call<T>(String method, [Object? arguments]) => _channel
      .invokeMethod<T>(method, arguments)
      .timeout(const Duration(seconds: 20));

  static Future<({List<SystemTtsEngine> engines, String? defaultEngine})>
  engines() async {
    final data = await _call<Map<Object?, Object?>>('engines');
    return (
      engines: [
        for (final item in (data?['engines'] as List? ?? const []))
          if (item is Map)
            SystemTtsEngine(item['package'] as String, item['label'] as String),
      ],
      defaultEngine: data?['defaultEngine'] as String?,
    );
  }

  static Future<int> initialize(SystemTtsPreferences prefs) async =>
      await _call<int>('initialize', {
        'engine': prefs.engine,
        'rate': prefs.rate,
      }) ??
      4000;
  static Future<void> speak(String text, String id) =>
      _call<void>('speak', {'text': text, 'id': id});
  static Future<void> stop() => _call<void>('stop');
  static Future<void> shutdown() => _call<void>('shutdown');
  static Future<void> openSettings() => _call<void>('settings');

  static String errorMessage(Object error) => switch (error) {
    PlatformException(:final message) => message ?? '系统朗读失败，请检查引擎配置',
    MissingPluginException() => '当前平台不支持系统朗读',
    TimeoutException() => '朗读响应超时，请重试或更换引擎',
    StateError(:final message) => message,
    _ => '无法加载正文或朗读引擎，请重试',
  };
}

class SystemTtsPreferences {
  const SystemTtsPreferences({this.engine, this.rate = 1});
  final String? engine;
  final double rate;

  static Future<SystemTtsPreferences> load() async {
    final sp = await SharedPreferences.getInstance();
    final rate = sp.getDouble('system_tts_rate') ?? 1;
    return SystemTtsPreferences(
      engine: sp.getString('system_tts_engine'),
      rate: rate.isFinite ? rate.clamp(0.5, 2) : 1,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    if (engine == null) {
      await sp.remove('system_tts_engine');
    } else {
      await sp.setString('system_tts_engine', engine!);
    }
    await sp.setDouble('system_tts_rate', rate);
  }
}

/// All sources are data/store references. No reader State or BuildContext is
/// retained when loading the following chapter after the reader has closed.
class SystemTtsBook {
  SystemTtsBook({
    required this.bookId,
    required this.title,
    this.coverUrl = '',
    required List<Chapter> chapters,
    required this.startIndex,
    required this.initialContent,
    this.startOffset = 0,
    this.localOnly = false,
    this.textLoader,
    this.cache,
    TextReplacementSnapshot? replacementSnapshot,
    TextReplacementStore? replacementStore,
  }) : replacementStore = replacementStore ?? TextReplacementStore.instance,
       replacementSnapshot =
           replacementSnapshot ??
           (replacementStore ?? TextReplacementStore.instance).snapshot,
       chapters = List.unmodifiable(chapters);

  final String bookId;
  final String title;

  /// 当前书的封面地址：交给 `ListenKeepAliveService` 当通知大图与媒体卡封面，
  /// 与听书走同一条通路（官方 `dn2/i.java` 的 `setLargeIcon`）。空串时退回
  /// 应用图标。
  final String coverUrl;

  final List<Chapter> chapters;
  final int startIndex;
  final ChapterContent initialContent;
  final int startOffset;
  final bool localOnly;
  final Future<String> Function(Chapter)? textLoader;
  final ChapterCache? cache;
  final TextReplacementSnapshot replacementSnapshot;
  final TextReplacementStore replacementStore;

  Future<TextReplacementResult> loadDisplay(
    int index, {
    BackendRequest? request,
    TextReplacementCancellation? cancellation,
  }) async {
    final content = await load(index, request: request);
    return TextReplacementEngine.instance.transform(
      source: content,
      chapterTitle: chapters[index].title,
      snapshot: replacementSnapshot,
      cancellation: cancellation,
    );
  }

  Future<ChapterContent> load(int index, {BackendRequest? request}) async {
    if (index == startIndex) return initialContent;
    final chapter = chapters[index];
    final loader = textLoader;
    if (localOnly) {
      if (loader == null) throw StateError('本地书籍正文不可用');
      return ChapterContent.fromCacheText(await loader(chapter));
    }
    try {
      final cached = await (cache ?? ChapterCacheStore.instance).read(
        bookId: bookId,
        chapterId: chapter.itemId,
      );
      if (cached != null) {
        final content = ChapterContent.fromCacheText(cached);
        if (!content.withoutLeadingTitle(chapter.title).isEmpty) return content;
      }
    } catch (_) {
      // Online novels retain their normal network fallback on a cache miss.
    }
    if (loader != null) {
      return ChapterContent.fromCacheText(await loader(chapter));
    }
    if (request?.isCancelled ?? false) throw BackendRequestAborted('已停止朗读');
    return ApiClient.instance.withCancellation(
      request ?? BackendRequest(),
      () => ApiClient.instance.chapterContent(chapter.itemId),
    );
  }

  static String plainText(ChapterContent content, String title) => content
      .withoutLeadingTitle(title)
      .blocks
      .whereType<ChapterParagraph>()
      .map((p) => p.text)
      .join('\n');
}

// Note: .agents/notes/implemented/feature/2026-10-15-system-tts.md
// The scope serializes ownership. Generations cancel deferred loads/play, and
// utterance IDs reject late callbacks after pause, chapter changes or shutdown.
class SystemTtsPlayback extends ChangeNotifier with WidgetsBindingObserver {
  SystemTtsPlayback(this.book, {required this.beforePlay, required this.onStop})
    : index = book.startIndex;

  final SystemTtsBook book;
  final Future<void> Function() beforePlay;
  final VoidCallback onStop;
  int index;
  bool loading = false;
  bool wantPlay = false;
  bool closed = false;
  bool completed = false;
  String? error;
  String _text = '';
  int _offset = 0;
  int _pieceStart = 0;
  int _pieceEnd = 0;
  int _generation = 0;
  int _serial = 0;
  int _maxLength = 300;
  String? _id;
  bool _ready = false;
  bool _started = false;

  /// Whether the current piece has reported an `onRangeStart`. Engines differ:
  /// the platform Speech Services callback word by word, several third-party
  /// Chinese voices never call it at all. [_offset] only advances on those
  /// callbacks, so without them a sentence-sized highlight would freeze on the
  /// first sentence of the piece — [_rangeCapable] remembers the engine's
  /// behaviour and keeps the whole piece as the range instead.
  bool _rangeSeen = false;
  bool _rangeCapable = false;
  bool _appActive = true;
  StreamSubscription<dynamic>? _subscription;
  Future<void> _notificationQueue = Future<void>.value();
  Future<void>? _closeFuture;
  BackendRequest? _loadRequest;
  TextReplacementCancellation? _replacementCancellation;

  Chapter get chapter => book.chapters[index];
  double get progress =>
      _text.isEmpty ? 0 : (_offset / _text.length).clamp(0, 1);
  bool get _allowed =>
      _appActive || AudioPreferences.instance.backgroundPlayback.value;

  void start() {
    if (_started || closed) return;
    _started = true;
    // Rule updates can occur while this book waits for history or ownership,
    // before this session has subscribed to future changes.
    if (book.replacementStore.snapshot.revision !=
        book.replacementSnapshot.revision) {
      _replacementChanged();
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    book.replacementStore.changes.addListener(_replacementChanged);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    AudioPreferences.instance.backgroundPlayback.addListener(
      _preferencesChanged,
    );
    _subscription = SystemTts.events.listen(
      _event,
      onError: (Object e) {
        if (!closed) unawaited(_fail(e));
      },
    );
    NativePlayer.setRemoteCommandHandler(
      onAction: (action) {
        if (closed) return;
        switch (action) {
          case 'playPause':
            unawaited(toggle());
          case 'prev':
            unawaited(openChapter(index - 1));
          case 'next':
            unawaited(openChapter(index + 1));
          case 'stop':
            onStop();
        }
      },
    );
    unawaited(openChapter(index, offset: book.startOffset));
  }

  Future<void> openChapter(int next, {int offset = 0}) async {
    if (closed || next < 0 || next >= book.chapters.length) return;
    final token = ++_generation;
    _loadRequest?.cancel();
    _replacementCancellation?.cancel();
    final cancellation = _replacementCancellation =
        TextReplacementCancellation();
    final request = _loadRequest = BackendRequest();
    _id = null;
    wantPlay = _allowed;
    loading = true;
    completed = false;
    error = null;
    index = next;
    _text = '';
    // The old piece belongs to the previous chapter's coordinates; keeping it
    // would let the reader paint a range that now points into other text.
    _pieceStart = 0;
    _pieceEnd = 0;
    _offset = offset;
    _publish();
    try {
      await SystemTts.stop();
      if (closed || token != _generation) return;
      final content = await book
          .loadDisplay(next, request: request, cancellation: cancellation)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              request.cancel();
              throw TimeoutException('正文加载超时');
            },
          );
      if (closed || token != _generation) return;
      _text = content
          .bodyBlocks(chapter.title)
          .whereType<ChapterParagraph>()
          .map((p) => p.text)
          .join('\n');
      if (_text.trim().isEmpty) throw StateError('本章没有可朗读的文字');
      _offset = _safeOffset(_offset.clamp(0, _text.length));
      loading = false;
      if (wantPlay) {
        await _begin(token);
      } else {
        _publish();
      }
    } catch (e) {
      if (!closed && token == _generation) await _fail(e);
    } finally {
      if (identical(_loadRequest, request)) _loadRequest = null;
    }
  }

  Future<void> _begin(int token) async {
    await beforePlay();
    if (!_current(token)) return;
    if (!_ready) {
      loading = true;
      _publish();
      final prefs = await SystemTtsPreferences.load();
      if (!_current(token)) return;
      _maxLength = (await SystemTts.initialize(prefs)).clamp(2, 300);
      if (!_current(token)) return;
      _ready = true;
    }
    loading = false;
    await _speak(token);
  }

  bool _current(int token) =>
      !closed && token == _generation && wantPlay && _allowed;

  int _safeOffset(int offset) {
    if (offset > 0 && offset < _text.length) {
      final unit = _text.codeUnitAt(offset);
      if (unit >= 0xdc00 && unit <= 0xdfff) return offset - 1;
    }
    return offset;
  }

  Future<void> _speak(int token) async {
    if (!_current(token)) return;
    if (_offset >= _text.length) {
      if (index + 1 < book.chapters.length) {
        await openChapter(index + 1);
      } else {
        completed = true;
        await pause();
      }
      return;
    }
    _pieceStart = _offset;
    // A piece that reported ranges proves the engine can do it; carry that
    // knowledge forward, the capability does not change between pieces.
    if (_rangeSeen) _rangeCapable = true;
    _rangeSeen = false;
    var end = _safeOffset((_offset + _maxLength).clamp(0, _text.length));
    // Short sentence-sized requests bound the rewind on engines without range
    // callbacks. Never split a UTF-16 surrogate pair at either boundary.
    for (var i = end - 1; i > _offset; i--) {
      if ('。！？!?；;\n'.contains(_text[i])) {
        end = i + 1;
        break;
      }
    }
    _pieceEnd = end;
    final id = '${identityHashCode(this)}-${++_serial}';
    _id = id;
    _publish();
    // Android 15+ requires foreground eligibility before requesting audio focus.
    await _notificationQueue;
    if (!_current(token) || _id != id) return;
    await SystemTts.speak(_text.substring(_pieceStart, end), id);
  }

  void _event(dynamic value) {
    if (closed || value is! Map) return;
    if (value['type'] == 'interrupted' && value['id'] == null) {
      unawaited(pause());
      return;
    }
    if (_id == null || value['id'] != _id) return;
    switch (value['type']) {
      case 'range':
        final start = value['start'];
        if (start is int && start >= 0 && start < _pieceEnd - _pieceStart) {
          _rangeSeen = true;
          _offset = _safeOffset(_pieceStart + start);
          _publish(notification: false);
        }
      case 'done':
        _id = null;
        _offset = _pieceEnd;
        final token = _generation;
        unawaited(
          _speak(token).catchError((Object e) async {
            if (!closed && token == _generation) await _fail(e);
          }),
        );
      case 'error':
        unawaited(_fail(StateError('引擎朗读失败，请检查音色或网络后重试')));
      case 'interrupted':
        unawaited(pause());
    }
  }

  Future<void> toggle() => wantPlay ? pause() : resume();

  Future<void> resume() async {
    if (closed || wantPlay || !_allowed) return;
    if (_text.isEmpty) {
      await openChapter(index, offset: _offset);
      return;
    }
    final token = ++_generation;
    wantPlay = true;
    error = null;
    if (completed) {
      _offset = 0;
      completed = false;
    }
    try {
      await _begin(token);
    } catch (e) {
      if (!closed && token == _generation) await _fail(e);
    }
  }

  Future<void> pause() async {
    if (closed) return;
    ++_generation;
    _loadRequest?.cancel();
    _id = null;
    wantPlay = false;
    loading = false;
    _publish();
    try {
      await SystemTts.stop();
    } catch (_) {}
  }

  Future<void> _fail(Object e) async {
    if (closed) return;
    error = SystemTts.errorMessage(e);
    _ready = false;
    await pause();
  }

  void _publish({bool notification = true}) {
    if (closed) return;
    ListeningSession.instance.update(
      bookId: book.bookId,
      chapterId: chapter.itemId,
      chapterTitle: chapter.title,
      position: Duration.zero,
      duration: Duration.zero,
      playing: wantPlay && !loading && error == null,
      textProgress: progress,
      textReplacementRevision: book.replacementSnapshot.revision,
      sentenceRange: sentenceHighlightRange(
        _text,
        offset: _offset,
        pieceStart: _pieceStart,
        pieceEnd: _pieceEnd,
        precise: _rangeCapable || _rangeSeen,
      ),
    );
    notifyListeners();
    if (notification) {
      _notificationQueue = _notificationQueue.then((_) async {
        if (closed) return;
        if (!AudioPreferences.instance.backgroundPlayback.value) {
          await NativePlayer.stopListenForeground();
        } else {
          await NativePlayer.startListenForeground(
            title: book.title,
            episode: '系统朗读 · ${chapter.title}',
            coverUrl: book.coverUrl,
            playing: wantPlay && !loading && error == null,
            hasPrev: index > 0,
            hasNext: index + 1 < book.chapters.length,
          );
        }
      });
    }
  }

  void _replacementChanged() {
    if (closed ||
        book.replacementStore.snapshot.revision ==
            book.replacementSnapshot.revision) {
      return;
    }
    // The owner also closes this session; close() is idempotent.
    unawaited(close());
    onStop();
  }

  void _preferencesChanged() {
    if (closed) return;
    if (!_allowed) {
      unawaited(pause());
    } else {
      _publish();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_allowed) unawaited(pause());
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    closed = true;
    _replacementCancellation?.cancel();
    book.replacementStore.changes.removeListener(_replacementChanged);
    ++_generation;
    _loadRequest?.cancel();
    _id = null;
    wantPlay = false;
    WidgetsBinding.instance.removeObserver(this);
    AudioPreferences.instance.backgroundPlayback.removeListener(
      _preferencesChanged,
    );
    NativePlayer.clearRemoteCommandHandler();
    ListeningSession.instance.clear();
    notifyListeners();
    // Do not await the EventChannel cancel: awaiting a platform-stream
    // subscription cancel stalls every later await in this zone (widget
    // tests hang in shutdown below), so fire it and forget it. Late events
    // are already ignored because `closed` is set above.
    unawaited(_subscription?.cancel());
    _subscription = null;
    try {
      await SystemTts.shutdown();
    } catch (_) {}
    await _notificationQueue;
    await NativePlayer.stopListenForeground();
    dispose();
  }
}
