/// Resolves a backend-relative resource path.
///
/// Backend-relative resources arrive as root-relative paths (`/src/...`).
/// They are returned as-is: there is no HTTP adapter anymore, so the path is
/// what the FFI image provider fetches, not a URL.
///
/// A value that already carries a scheme is not a backend-relative resource
/// and is returned verbatim: re-encoding it could invalidate the signature of
/// a signed CDN URL. A protocol-relative value (`//host/path`) inherits
/// `https:`, as a browser would.
String resolveBackendResource(String raw) {
  final parsed = Uri.parse(raw);
  if (parsed.hasScheme) return raw;
  if (parsed.host.isNotEmpty) return 'https:$raw';
  final path = parsed.path;
  if (path.startsWith('/')) return path;
  return '/$path';
}
