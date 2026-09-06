import 'dart:async';

import 'fakes.dart';

/// Delays individual native operations without changing the lightweight fake
/// used by the controls tests. A player becomes ready only after create ends.
class ControlledNativePlayer extends FakeNativePlayer {
  Completer<void>? createGate;
  Completer<void>? releaseGate;
  Completer<void>? seekGate;
  Completer<void>? rateGate;
  Completer<void>? playGate;
  bool _created = false;
  bool _completed = false;
  Future<void>? _release;
  bool hasFirstFrame;
  final firstFrames = StreamController<bool>.broadcast();

  ControlledNativePlayer({
    this.createGate,
    this.releaseGate,
    this.seekGate,
    this.rateGate,
    this.playGate,
    this.hasFirstFrame = true,
  }) {
    currentPosition = Duration.zero;
  }

  @override
  bool get isCreated => _created && !disposed;

  @override
  int? get textureId => isCreated ? 1 : null;

  @override
  bool get completed => _completed;

  @override
  bool get firstFrameRendered => hasFirstFrame;

  @override
  Stream<bool> get firstFrameStream => firstFrames.stream;

  void emitFirstFrame() {
    if (disposed) return;
    hasFirstFrame = true;
    firstFrames.add(true);
  }

  void emitBuffering(bool buffering) {
    if (disposed) return;
    isBuffering = buffering;
    bufferingEvents.add(buffering);
  }

  @override
  Future<int> create(String cdnUrl, String keyHex) async {
    calls.add('create:$cdnUrl');
    await createGate?.future;
    if (disposed) throw StateError('Player disposed during creation');
    _created = true;
    calls.add('created');
    return 1;
  }

  @override
  Future<void> play() async {
    if (disposed) return;
    calls.add('play');
    await playGate?.future;
    if (disposed) return;
    isPlaying = true;
    playingEvents.add(true);
  }

  @override
  Future<void> pause() async {
    if (disposed) return;
    await super.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    if (disposed) return;
    calls.add('seek:${position.inMilliseconds}ms');
    await seekGate?.future;
    if (disposed) return;
    emitPosition(position);
  }

  @override
  Future<void> setRate(double rate) async {
    if (disposed) return;
    calls.add('rate:$rate');
    await rateGate?.future;
    if (!disposed) this.rate = rate;
  }

  void emitPosition(Duration position) {
    if (disposed) return;
    currentPosition = position;
    positions.add(position);
  }

  void emitCompleted() {
    if (disposed) return;
    _completed = true;
    emitPosition(totalDuration);
    completedEvents.add(true);
  }

  @override
  Future<void> dispose() => _release ??= _dispose();

  Future<void> _dispose() async {
    calls.add('dispose');
    final closed = Future.wait([super.dispose(), firstFrames.close()]);
    await releaseGate?.future;
    await closed;
    calls.add('released');
  }
}

class ControlledReaderStore extends MemoryReaderStore {
  Completer<void>? writeGate;
  bool failNextWrite = false;
  bool failReadTime = false;
  final writes = <Map<String, dynamic>>[];

  ControlledReaderStore({super.entry});

  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
    final snapshot = Map<String, dynamic>.from(value);
    await writeGate?.future;
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('History write failed');
    }
    writes.add(snapshot);
    await super.addHistory(snapshot);
  }

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {
    if (failReadTime) throw StateError('Read time write failed');
    await super.accumulateReadTime(bookId, kind, seconds, at: at);
  }
}
