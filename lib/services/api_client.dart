import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import 'backend_service.dart';

/// API client talking to the local  backend.
///
/// Uses the same `/api/*` bridge the web UI uses, so responses are already
/// normalized for the frontend (search tabs, chapterListWithVolume, etc.).
class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  String get _base => BackendService.instance.baseUrl;

  /// Converts a backend-relative resource (`/src/foo.mp4`) into a URL the
  /// Flutter networking plugins can consume. JSON API paths stay untouched.
  String absoluteUrl(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return raw;
    final parsed = Uri.tryParse(raw);
    if (parsed != null && parsed.hasScheme) return raw;
    if (raw.startsWith('/')) return '$_base$raw';
    return '$_base/$raw';
  }

  /// Decodes and envelope-checks a response body on a background isolate so
  /// large JSON payloads never jank the UI thread.
  Future<Map<String, dynamic>> _decodeAsync(http.Response r) async {
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(() {
      if (statusCode != 200) {
        throw ApiException('HTTP $statusCode');
      }
      final j = jsonDecode(utf8.decode(bodyBytes));
      if (j is Map<String, dynamic>) {
        // The web bridge uses code=200; REST upstream-compatible endpoints use
        // code=0. Both are successful envelopes.
        if (j['code'] != null && j['code'] != 200 && j['code'] != 0) {
          throw ApiException('${j['message'] ?? '请求失败'}');
        }
        if (j['success'] == false) {
          throw ApiException('${j['error'] ?? j['message'] ?? '请求失败'}');
        }
        return j;
      }
      throw ApiException('响应格式错误');
    });
  }

  /// Search across content types.
  /// Returns normalized {tabs: [{title, data:[...]}], ...} structure.
  Future<Map<String, dynamic>> search(String query, {int page = 1}) async {
    final r = await http.get(
      Uri.parse(
        '$_base/api/search?source=${Uri.encodeQueryComponent('番茄')}&query=${Uri.encodeQueryComponent(query)}&page=$page',
      ),
    );
    return _decodeAsync(r);
  }

  /// Book detail.
  Future<Map<String, dynamic>> detail(
    String bookId, {
    String tab = '小说',
  }) async {
    final r = await http.get(
      Uri.parse(
        '$_base/api/detail?source=${Uri.encodeQueryComponent('番茄')}&book_id=$bookId&tab=${Uri.encodeQueryComponent(tab)}',
      ),
    );
    return _decodeAsync(r);
  }

  /// Book directory — returns data.data.chapterListWithVolume.
  Future<Map<String, dynamic>> directory(
    String bookId, {
    String tab = '小说',
  }) async {
    final r = await http.get(
      Uri.parse(
        '$_base/api/directory?source=${Uri.encodeQueryComponent('番茄')}&book_id=$bookId&tab=${Uri.encodeQueryComponent(tab)}',
      ),
    );
    return _decodeAsync(r);
  }

  /// Chapter content (decrypted by backend).
  Future<Map<String, dynamic>> content(
    String itemId, {
    String tab = '小说',
    String? toneId,
    String? mode,
  }) async {
    final r = await http.get(
      Uri.parse(
        '$_base/api/content?source=${Uri.encodeQueryComponent('番茄')}&item_id=$itemId&tab=${Uri.encodeQueryComponent(tab)}${toneId != null ? '&tone_id=$toneId' : ''}${mode != null ? '&mode=$mode' : ''}',
      ),
    );
    return _decodeAsync(r);
  }

  /// Resolve a share URL to a book id.
  Future<Map<String, dynamic>> resolve(String url) async {
    final r = await http.get(
      Uri.parse('$_base/api/resolve?url=${Uri.encodeQueryComponent(url)}'),
    );
    return _decodeAsync(r);
  }

  /// Real homepage recommendations (the Flutter home page previously used a
  /// search for the literal word "推荐", which is not a recommendation API).
  ///
  /// [sessionId] must be echoed back when paging a tab (e.g. tab_type=8 看剧):
  /// the upstream binds the session to the device that opened it, and the
  /// backend pins that device across pages so pagination does not 101116.
  Future<Map<String, dynamic>> homepageRecommend({
    int tabType = 2,
    int offset = 0,
    String? sessionId,
  }) async {
    final session = sessionId == null || sessionId.isEmpty
        ? ''
        : '&session_id=${Uri.encodeQueryComponent(sessionId)}';
    final r = await http.get(
      Uri.parse(
        '$_base/api/v1/recommend/homepage?tab_type=$tabType&offset=$offset$session',
      ),
    );
    return _decodeAsync(r);
  }

  /// Health check.
  Future<bool> health() async {
    try {
      final r = await http
          .get(Uri.parse('$_base/health'))
          .timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}
