import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'api_client.dart';

/// Whether [url] names a backend-managed resource (`/src/...`) instead of a
/// network URL.
///
/// Backend resources (manga pages, chapter illustrations) live in the Rust
/// core's `src/` directory and are fetched through the FFI bridge, never over
/// HTTP - the core listens on no socket. Everything else is a CDN URL and
/// keeps its existing network provider.
bool isBackendResourceUrl(String url) => url.startsWith('/src/');

/// Cache key for [BackendImageProvider]: the backend path plus the device
/// pixel ratio, mirroring [NetworkImage].
@immutable
class BackendImageKey {
  const BackendImageKey(this.path, this.scale);

  final String path;
  final double scale;

  @override
  bool operator ==(Object other) =>
      other is BackendImageKey &&
      other.path == path &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(path, scale);
}

/// Loads a backend-managed image (`/src/...`) through the FFI bridge.
///
/// Bytes come from [ApiClient.fetchBackendResource], so they only ever enter
/// Flutter's in-memory [ImageCache] - never a disk cache, which is what the
/// old loopback URLs required too (a disk entry would outlive the launch
/// that produced it). [ResizeImage] still wraps this provider where a decode
/// bound is needed; it re-decodes through [loadImage] like any other provider.
class BackendImageProvider extends ImageProvider<BackendImageKey> {
  const BackendImageProvider(this.path, {this._apiClient});

  /// Backend path, e.g. `/src/abc.webp`.
  final String path;
  final ApiClient? _apiClient;

  @override
  Future<BackendImageKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(
      BackendImageKey(path, configuration.devicePixelRatio ?? 1.0),
    );
  }

  @override
  ImageStreamCompleter loadImage(
    BackendImageKey key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: 'BackendImageProvider(${key.path})',
    );
  }

  Future<ui.Codec> _loadAsync(
    BackendImageKey key,
    ImageDecoderCallback decode,
  ) async {
    final client = _apiClient ?? ApiClient.instance;
    final bytes = await client.fetchBackendResource(key.path);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }
}
