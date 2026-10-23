import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Pulls the openable page out of an upstream app link.
///
/// The bookstore feed links with `dragon1967://`: a page arrives as
/// `dragon1967://webview?url=<https…>` and a Lynx card as
/// `dragon1967://lynxview?fallbackUrl=dragon1967://webview?url=<https…>` (both
/// shapes are in the 书荒广场 card of `build/home_raw.json`). Only the official
/// app registers that scheme, so handing it to the system fails on any other
/// install — the https page nested in the query is what this client can show.
///
/// Returns null when no `http(s)` URL is reachable, which is the case for the
/// Lynx template link: its inner target is an `sslocal://lynxview` bundle, not
/// a page. Callers then show the usual failure hint instead of opening
/// nothing.
///
/// [depth] bounds the nesting: `lynxview → webview → page` is already three
/// levels, and a link that keeps pointing at itself must not spin here.
Uri? resolveAppLink(String raw, {int depth = 0}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || depth > 3) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;

  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' || scheme == 'https') return uri;

  // `url` is the page a `webview` wraps; `fallbackUrl` is what a `lynxview`
  // falls back to when its template cannot run.
  for (final key in const ['url', 'fallbackUrl']) {
    final inner = uri.queryParameters[key];
    if (inner == null || inner.isEmpty) continue;
    final resolved = resolveAppLink(inner, depth: depth + 1);
    if (resolved != null) return resolved;
  }
  return null;
}

/// Opens an upstream app link in the system browser.
///
/// Same policy as the rest of the app: no `canLaunchUrl` pre-check (Android
/// package visibility hides browsers from it even though they handle the
/// intent), and every failure surfaces as one visible hint.
Future<void> openAppLink(BuildContext context, String raw) async {
  final uri = resolveAppLink(raw);
  var launched = false;
  if (uri != null) {
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Report launch failures through the same visible fallback.
    }
  }
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开链接')));
  }
}
