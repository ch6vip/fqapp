import 'dart:async';

import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/native_player.dart';

class MemoryReaderStore implements ReaderStore {
  Map<String, dynamic>? entry;
  double seconds = 0;
  MemoryReaderStore({this.entry});

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async => entry;

  @override
  Future<void> addHistory(Map<String, dynamic> value) async =>
      entry = Map<String, dynamic>.from(value);

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {
    entry = {
      ...?entry,
      'id': id,
      'episode': episode,
      'progress': progress,
      'chapterId': ?chapterId,
      'position': ?position,
      'maxScroll': ?maxScroll,
    };
  }

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async => this.seconds += seconds;
}

class MemoryChapterCache implements ChapterCache {
  final Map<String, Map<String, String>> content = {};
  final Map<String, CachedBook> catalogs = {};

  @override
  Future<String?> read({
    required String bookId,
    required String chapterId,
  }) async => content[bookId]?[chapterId];

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
  }) async {
    (content[bookId] ??= {})[chapterId] = text;
  }

  @override
  Future<void> saveBook(CachedBook book) async => catalogs[book.id] = book;

  @override
  Future<Set<String>> cachedChapterIds(String bookId) async =>
      content[bookId]?.keys.toSet() ?? {};
}

class FakeNativePlayer extends NativePlayer {
  int width;
  int height;

  FakeNativePlayer({this.width = 1920, this.height = 1080});

  final calls = <String>[];
  Duration currentPosition = const Duration(seconds: 20);
  Duration totalDuration = const Duration(minutes: 2);
  bool isPlaying = false;
  bool isBuffering = false;
  bool disposed = false;
  double rate = 1;
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration>.broadcast(sync: true);
  final playingEvents = StreamController<bool>.broadcast(sync: true);
  final completedEvents = StreamController<bool>.broadcast(sync: true);
  final bufferingEvents = StreamController<bool>.broadcast(sync: true);
  final errors = StreamController<Object>.broadcast(sync: true);

  @override
  bool get isCreated => !disposed;
  @override
  int? get textureId => 1;
  @override
  Duration get position => currentPosition;
  @override
  Duration get duration => totalDuration;
  @override
  bool get playing => isPlaying;
  @override
  bool get completed => false;
  @override
  bool get buffering => isBuffering;
  @override
  bool get firstFrameRendered => true;
  @override
  int get videoWidth => width;
  @override
  int get videoHeight => height;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration> get durationStream => durations.stream;
  @override
  Stream<bool> get playingStream => playingEvents.stream;
  @override
  Stream<bool> get completedStream => completedEvents.stream;
  @override
  Stream<bool> get bufferingStream => bufferingEvents.stream;
  @override
  Stream<Object> get errorStream => errors.stream;

  @override
  Future<int> create(String cdnUrl, String keyHex) async {
    calls.add('create:$cdnUrl');
    return 1;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    isPlaying = true;
    playingEvents.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    isPlaying = false;
    playingEvents.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inSeconds}');
    currentPosition = position;
    positions.add(position);
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('rate:$rate');
    this.rate = rate;
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await Future.wait([
      positions.close(),
      durations.close(),
      playingEvents.close(),
      completedEvents.close(),
      bufferingEvents.close(),
      errors.close(),
    ]);
    await super.dispose();
  }
}
