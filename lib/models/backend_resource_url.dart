/// Resolves a backend-relative resource path against a capability-carrying
/// base URL.
///
/// The loopback adapter demands a per-launch capability on every request, and
/// the capability travels inside the path (`http://127.0.0.1:8080/_session/<cap>/`).
/// Backend-relative resources arrive as root-relative paths (`/src/...`), and
/// `Uri.resolve` reads a leading `/` as "root-relative", which would replace the
/// whole base path and drop the `/_session/<cap>` segment - leaving every cover,
/// video, audio and manga request at a 401. Re-anchoring the path under the base
/// keeps the segment.
///
/// A value that already carries a scheme is not a backend-relative resource and
/// is returned verbatim: re-encoding it could invalidate the signature of a
/// signed CDN URL. A protocol-relative value (`//host/path`) keeps resolving
/// against the base, as it did before.
String resolveBackendResource(String base, String raw) {
  final parsed = Uri.parse(raw);
  if (parsed.hasScheme) return raw;
  final path = parsed.path.replaceFirst(RegExp('^/+'), '');
  return Uri.parse(base).resolveUri(parsed.replace(path: path)).toString();
}
