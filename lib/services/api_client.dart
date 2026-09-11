import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../models/audio_extra.dart';
import '../models/author_profile.dart';
import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/chapter_ideas.dart';
import '../models/chapter_media.dart';
import '../models/chapter_summary.dart';
import '../models/comment_reply.dart';
import '../models/media_item.dart';
import '../models/media_id.dart';
import '../models/rank.dart';
import '../models/search_discovery.dart';
import '../models/series_detail.dart';
import 'backend_service.dart';
import 'chapter_text_formatter.dart';

/// A parsed homepage page. Keeping the cursor next to the parsed cards lets
/// callers update the feed atomically after checking that the request is
/// still current.
class HomepagePage {
  final List<MediaItem> items;
  final int? nextOffset;
  final String? sessionId;

  const HomepagePage({
    required this.items,
    required this.nextOffset,
    required this.sessionId,
  });
}

/// API client talking to the local  backend.
///
/// Uses the same `/api/*` bridge the web UI uses, so responses are already
/// normalized for the frontend (search tabs, chapterListWithVolume, etc.).
class ApiClient {
  ApiClient({
    http.Client? client,
    String? baseUrl,
    this._timeout = const Duration(seconds: 20),
    this._comicTimeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client(),
       _base = baseUrl ?? BackendService.instance.baseUrl;

  static final ApiClient instance = ApiClient();

  // Reuse sockets for the lifetime of the app. All requests target the same
  // loopback backend, so creating a new Client for every call only adds TCP
  // setup and TIME_WAIT churn.
  final http.Client _client;

  /// Timeout applied to every backend request. The backend runs locally, so a
  /// healthy call returns in well under this; a hung child process or a stuck
  /// upstream request must not leave a page spinning forever.
  final Duration _timeout;

  // Encrypted comic chapters are downloaded and decrypted by the backend
  // before its JSON response is ready, so they need a separate finite limit.
  final Duration _comicTimeout;

  final String _base;

  /// Converts a backend-relative resource (`/src/foo.mp4`) into a URL the
  /// Flutter networking plugins can consume. JSON API paths stay untouched.
  String absoluteUrl(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return raw;
    final parsed = Uri.tryParse(raw);
    if (parsed != null && parsed.hasScheme) return raw;
    return Uri.parse(_base).resolve(raw).toString();
  }

  /// Decodes and envelope-checks a response body on a background isolate so
  /// large JSON payloads never jank the UI thread.
  Future<Map<String, dynamic>> _decodeAsync(http.Response r) async {
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(() => _decodeEnvelope(statusCode, bodyBytes));
  }

  /// Sends a request to the local backend with a timeout.
  ///
  /// [method] exists for the few bridge endpoints that are POST-only upstream
  /// (comment replies); callers still pass their arguments as query parameters,
  /// which the backend reads from the URL either way.
  Future<http.Response> _get(
    String url, {
    Duration? timeout,
    String method = 'GET',
  }) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      method,
      Uri.parse(url),
      abortTrigger: abort.future,
    );
    try {
      return await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout ?? _timeout);
    } on TimeoutException {
      // Future.timeout alone leaves a hung request occupying a connection.
      // Cancel this request without closing the shared client's other calls.
      abort.complete();
      rethrow;
    }
  }

  String _url(String path, Map<String, String> query) =>
      Uri.parse(_base).resolve(path).replace(queryParameters: query).toString();

  String _searchUrl(String query, int page) =>
      _url('/api/search', {'source': '番茄', 'query': query, 'page': '$page'});

  String _directoryUrl(String bookId, String tab) =>
      _url('/api/directory', {'source': '番茄', 'book_id': bookId, 'tab': tab});

  /// Search across content types.
  /// Returns normalized {tabs: [{title, data:[...]}], ...} structure.
  Future<Map<String, dynamic>> search(String query, {int page = 1}) async {
    final r = await _get(_searchUrl(query, page));
    return _decodeAsync(r);
  }

  /// Search with JSON decoding and model parsing combined into one isolate
  /// hop. This avoids decoding a large response in one isolate and then
  /// copying the resulting map into a second isolate for normalization.
  Future<List<SearchTab>> searchTabs(
    String query, {
    int page = 1,
    int? tabType,
    int? offset,
  }) async {
    final searchOffset = offset ?? (page > 1 ? page - 1 : 0) * 10;
    final url = tabType == null
        ? _searchUrl(query, page)
        : _url('/api/v1/search', {
            'query': query,
            'tab_type': '$tabType',
            'offset': '${searchOffset < 0 ? 0 : searchOffset}',
            'count': '10',
          });
    final r = await _get(url);
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(
      () => parseSearchTabs(
        _decodeEnvelope(statusCode, bodyBytes),
        tabType: tabType,
      ),
    );
  }

  // Note: ID 识别、精确匹配与目录回退见 .agents/notes/implemented/feature/2026-09-10-id-search.md
  Future<MediaItem?> lookupMediaById(String input) async {
    final id = input.trim();
    if (!isValidMediaId(id)) {
      throw const ApiException('作品 ID 需为 1 至 20 位数字，且不能全为 0');
    }
    Exception? failure;
    StackTrace? failureStack;
    for (final endpoint in ['detail', 'directory']) {
      try {
        final response = await _get(_url('/api/v1/books/$id/$endpoint', {}));
        final status = response.statusCode;
        final bytes = response.bodyBytes;
        final item = await Isolate.run(
          () => parseMediaIdResult(_decodeEnvelope(status, bytes), id),
        );
        if (item != null) return item;
      } on Exception catch (error, stack) {
        if (error is ApiException) {
          // BOOK_NOT_EXIST_ERROR is a definitive lookup result. Requesting
          // a directory for it adds delay and can obscure it with a timeout.
          if (error.upstreamCode == 101104) break;
          if (error.statusCode == 404) continue;
        }
        failure = error;
        failureStack = stack;
      }
    }
    // An unavailable source is retryable; it must not become "no results".
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    return null;
  }

  /// Book detail.
  Future<Map<String, dynamic>> detail(
    String bookId, {
    String tab = '小说',
  }) async {
    final r = await _get(
      _url('/api/detail', {'source': '番茄', 'book_id': bookId, 'tab': tab}),
    );
    return _decodeAsync(r);
  }

  /// Book directory — returns data.data.chapterListWithVolume.
  Future<Map<String, dynamic>> directory(
    String bookId, {
    String tab = '小说',
  }) async {
    final r = await _get(_directoryUrl(bookId, tab));
    return _decodeAsync(r);
  }

  /// Directory variant that performs decode + chapter normalization in the
  /// same background isolate.
  Future<List<List<Chapter>>> directoryChapters(
    String bookId, {
    String tab = '小说',
  }) async {
    final r = await _get(_directoryUrl(bookId, tab));
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(
      () => parseDirectory(_decodeEnvelope(statusCode, bodyBytes)),
    );
  }

  /// Chapter content (decrypted by backend).
  String _contentUrl(
    String itemId, {
    required String tab,
    String? toneId,
    String? mode,
  }) => _url('/api/content', {
    'source': '番茄',
    'item_id': itemId,
    'tab': tab,
    'tone_id': ?toneId,
    'mode': ?mode,
  });

  Future<Map<String, dynamic>> content(
    String itemId, {
    String tab = '小说',
    String? toneId,
    String? mode,
  }) async {
    final r = await _get(
      _contentUrl(itemId, tab: tab, toneId: toneId, mode: mode),
    );
    return _decodeAsync(r);
  }

  /// With a book ID, resolve the real playback model directly. The speech
  /// bridge often contains only subtitles and remains a legacy fallback for
  /// callers that do not have a book ID.
  Future<AudioSource> audioSource(
    String itemId, {
    String? toneId,
    String? bookId,
  }) async {
    final usePlayback = bookId != null && bookId.trim().isNotEmpty;
    final selectedTone = toneId == null || toneId.trim().isEmpty
        ? (usePlayback ? '0' : '1')
        : toneId.trim();
    final response = await _get(
      usePlayback
          ? _url('/api/v1/audio/play', {
              'book_id': bookId,
              'item_ids': itemId,
              'tone_id': selectedTone,
            })
          : _contentUrl(itemId, tab: '听书', toneId: selectedTone),
    );
    final statusCode = response.statusCode;
    final bodyBytes = response.bodyBytes;
    final baseUrl = _base;
    return Isolate.run(() {
      try {
        return parseAudioSource(
          _decodeEnvelope(statusCode, bodyBytes),
          itemId: itemId,
          toneId: selectedTone,
          baseUrl: baseUrl,
        );
      } on FormatException catch (error) {
        throw ApiException(error.message);
      }
    });
  }

  /// Voice IDs come from ordinary book detail, as in the existing web player.
  /// Optional metadata failures must not prevent playing the default voice.
  Future<List<AudioVoice>> audioVoices(String bookId) async {
    try {
      return parseAudioVoices(await detail(bookId, tab: '小说'));
    } on Exception {
      return defaultAudioVoices;
    }
  }

  // --- Rich detail metadata -------------------------------------------------
  // The endpoints below feed the redesigned detail and listening pages. All of
  // them are optional decoration: a failure must degrade to a hidden section
  // rather than an error page, so each loader is wrapped by its caller.

  /// Rich book metadata (category, word count, rating, tags, author level…).
  /// Returns an empty model when the backend has no detail record.
  Future<BookDetail> bookDetail(String bookId) async {
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/detail', {}),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => BookDetail.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// Book reviews plus the counters shown above them.
  Future<BookCommentPage> bookComments(
    String bookId, {
    int count = 10,
    int offset = 0,
  }) async {
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/comments', {
        'count': '$count',
        'offset': '$offset',
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => BookCommentPage.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// Companion works: the original novel and any short-drama adaptation.
  Future<List<RelatedWork>> relatedWorks(String bookId) async {
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/related', {}),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => RelatedWork.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// 智能朗读 / 真人讲书 voices with their display names.
  Future<AudioToneSet> bookTones(String bookId) async {
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/tones', {}),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => AudioToneSet.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// 边听边读 subtitles for one chapter.
  ///
  /// `genre` and `tone_id` are mandatory for a usable answer: the backend
  /// defaults (`genre=4`, `tone_id=99`) always return `1301008 no available
  /// speech text`, while a real tone id with `genre=1` returns the track. A
  /// book without generated speech text yields [SubtitleTrack.empty].
  Future<SubtitleTrack> chapterTimeline(
    String itemId, {
    String toneId = '1',
    int genre = 1,
  }) async {
    try {
      final response = await _get(
        _url('/api/v1/chapters/${Uri.encodeComponent(itemId)}/timeline', {
          'genre': '$genre',
          'tone_id': toneId,
        }),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return Isolate.run(() {
        final payload = _decodeEnvelope(status, bytes);
        // "No speech text" is a normal, expected answer, not a failure.
        if (isUnavailableCode(payload['code'])) return SubtitleTrack.empty;
        return SubtitleTrack.fromPayload(payload);
      });
    } on Exception {
      return SubtitleTrack.empty;
    }
  }

  /// Chapter ideas (段评 / 章评): per-paragraph counts and comment ids.
  ///
  /// These come from the item-ideas service, not the book review list — the
  /// latter rejects the item and paragraph comment types outright. The payload
  /// carries counts and comment ids only; comment bodies need a second call
  /// through [bookReviews] with the paragraph recipe.
  Future<ChapterIdeas> chapterIdeas(
    String itemId, {
    String? itemVersion,
    int commentSource = 3,
  }) async {
    try {
      final response = await _get(
        _url('/api/v1/chapters/${Uri.encodeComponent(itemId)}/reviews', {
          'comment_source': '$commentSource',
          if (itemVersion != null && itemVersion.isNotEmpty)
            'item_version': itemVersion,
        }),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return Isolate.run(() {
        final payload = _decodeEnvelope(status, bytes);
        if (isUnavailableIdeaCode(payload['code'])) return ChapterIdeas.empty;
        return ChapterIdeas.fromPayload(payload);
      });
    } on Exception {
      // Ideas are decoration; a failure must not break chapter loading.
      return ChapterIdeas.empty;
    }
  }

  /// Comment bodies for one paragraph.
  ///
  /// This is the official client's paragraph-comment recipe: the container is
  /// the **chapter item id** while `business_param.book_id` stays the real book
  /// id, and the upstream rejects the request with
  /// `103001 book_id, item_version, or para_index invalid` unless all three of
  /// `book_id`, [itemVersion] and [paraIndex] are usable.
  Future<BookCommentPage> paragraphComments(
    String bookId,
    String itemId, {
    required String itemVersion,
    required int paraIndex,
    int count = 20,
  }) async {
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/reviews', {
        'book_id': bookId,
        'group_id': itemId,
        'group_type': '15',
        'comment_source': '2',
        'comment_type': '1',
        'server_channel': '43',
        'para_index': '$paraIndex',
        'item_version': itemVersion,
        'count': '$count',
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => parseParagraphComments(_decodeEnvelope(status, bytes)),
    );
  }

  // --- Discovery: suggestions, hot search, authors, ranks ------------------

  /// Query suggestions for the text being typed. Returns an empty list on
  /// failure: the field is an aid, never a blocker to searching.
  Future<List<SearchSuggestion>> searchSuggestions(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    try {
      final response = await _get(
        _url('/api/v1/search/suggest', {'q': trimmed}),
        timeout: const Duration(seconds: 10),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return Isolate.run(
        () => SearchSuggestion.fromPayload(_decodeEnvelope(status, bytes)),
      );
    } on Exception {
      return const [];
    }
  }

  /// The hot search board, used to fill the empty search screen.
  Future<HotSearch> hotSearch() async {
    try {
      final response = await _get(_url('/api/v1/search/hot', {}));
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return Isolate.run(
        () => HotSearch.fromPayload(_decodeEnvelope(status, bytes)),
      );
    } on Exception {
      return HotSearch.empty;
    }
  }

  /// Author profile plus their catalogue. Returns [AuthorProfile.empty] on
  /// failure so the page can show a retry instead of crashing.
  Future<AuthorProfile> authorProfile(String authorId) async {
    final response = await _get(
      _url('/api/v1/authors/${Uri.encodeComponent(authorId)}', {}),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => AuthorProfile.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// The rank catalogue, which the upstream ships inside the novel homepage
  /// payload rather than on an endpoint of its own.
  Future<RankCatalog> rankCatalog() async {
    try {
      final response = await _get(_homepageUrl(2, 0, null));
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return Isolate.run(
        () => RankCatalog.fromHomepagePayload(_decodeEnvelope(status, bytes)),
      );
    } on Exception {
      return RankCatalog.empty;
    }
  }

  /// One page of a rank. [algo] is the catalogue's `rank_algo`, [categoryId] its
  /// `info_id` (0 = 全部).
  Future<RankBoard> rankBoard({
    required String rankId,
    required int algo,
    int categoryId = 0,
    int offset = 0,
    int startAt = 1,
  }) async {
    final response = await _get(
      _url('/api/v1/rank/${Uri.encodeComponent(rankId)}', {
        'algo_type': '$algo',
        'rank_sub_info_id': '$categoryId',
        if (offset > 0) 'offset': '$offset',
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => RankCatalog.parsePage(
        _decodeEnvelope(status, bytes),
        startAt: startAt,
      ),
    );
  }

  /// Replies to one review. All three ids are required by the backend.
  Future<CommentReplyPage> commentReplies(
    String bookId,
    String commentId, {
    required String groupId,
    int count = 10,
  }) async {
    final response = await _get(
      _url('/api/v1/comments/${Uri.encodeComponent(commentId)}/replies', {
        'comment_id': commentId,
        'group_id': groupId,
        'book_id': bookId,
        'count': '$count',
      }),
      method: 'POST',
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => CommentReplyPage.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// Chapter previews for the given chapter item ids.
  Future<ChapterSummary> chapterSummaries(
    String bookId,
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty) return ChapterSummary.empty;
    try {
      final response = await _get(
        _url('/api/v1/books/${Uri.encodeComponent(bookId)}/chapters/summary', {
          'item_ids': itemIds.join(','),
        }),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return Isolate.run(
        () => ChapterSummary.fromPayload(_decodeEnvelope(status, bytes)),
      );
    } on Exception {
      return ChapterSummary.empty;
    }
  }

  /// Resolves specific comment bodies by id.  ///
  /// The idea list returns comment ids without bodies, so this is the second
  /// hop of the chapter-ideas chain: `insert_comment_ids` asks the comment list
  /// for exactly those entries. The container stays the chapter item id, which
  /// is what the upstream expects for comments anchored to a chapter.
  Future<BookCommentPage> commentsByIds(
    String bookId,
    String itemId,
    List<String> commentIds,
  ) async {
    if (commentIds.isEmpty) return const BookCommentPage();
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/reviews', {
        'book_id': bookId,
        'group_id': itemId,
        'insert_comment_ids': commentIds.join(','),
        'count': '${commentIds.length}',
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => parseParagraphComments(_decodeEnvelope(status, bytes)),
    );
  }

  /// Short-drama series detail, including the cast list.
  ///
  /// The reading-API detail and directory responses carry no cast data, so the
  /// actor row needs this call. A failure yields [SeriesDetail.empty] — the row
  /// is decoration and must not break a playable series.
  Future<SeriesDetail> seriesDetail(String seriesId) async {
    try {
      final response = await _get(
        _url('/api/v1/series/${Uri.encodeComponent(seriesId)}', {}),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return Isolate.run(
        () => SeriesDetail.fromPayload(_decodeEnvelope(status, bytes)),
      );
    } on Exception {
      return SeriesDetail.empty;
    }
  }

  /// Returns comic pages in backend order with absolute HTTP(S) URLs.
  Future<List<ComicImage>> comicImages(String itemId) async {
    final response = await _get(
      _contentUrl(itemId, tab: '漫画'),
      timeout: _comicTimeout,
    );
    final statusCode = response.statusCode;
    final bodyBytes = response.bodyBytes;
    final baseUrl = _base;
    return Isolate.run(() {
      try {
        return parseComicImages(
          _decodeEnvelope(statusCode, bodyBytes),
          baseUrl: baseUrl,
        );
      } on FormatException catch (error) {
        throw ApiException(error.message);
      }
    });
  }

  /// Text-reader variant that combines JSON decode, nested content lookup and
  /// HTML cleanup in one background-isolate pass.
  Future<String> contentText(String itemId, {String tab = '小说'}) async {
    final r = await _get(_contentUrl(itemId, tab: tab));
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(() {
      final payload = _decodeEnvelope(statusCode, bodyBytes);
      return _extractChapterText(payload);
    });
  }

  // Note: 图文接口的解密标记与旧缓存升级见
  // .agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md
  Future<ChapterContent> chapterContent(String itemId) async {
    try {
      final response = await _get(
        _url('/api/v1/chapters/${Uri.encodeComponent(itemId)}/novel', {}),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      final baseUrl = _base;
      return await Isolate.run(() {
        final payload = _decodeEnvelope(status, bytes);
        final data = payload['data'];
        // Older backends return code=0 with ciphertext still in content.
        // Only consume a chapter the backend explicitly decrypted successfully.
        if (data is! Map ||
            data['content_decrypted'] != true ||
            data['content'] is! String) {
          throw const ApiException('图文正文尚未解密');
        }
        final content = parseChapterContent(
          data['content'] as String,
          baseUrl: baseUrl,
        );
        if (content.isEmpty) throw const ApiException('正文为空');
        return content;
      });
    } on Exception {
      // Keep text available if the illustrated source is temporarily down.
      // The cache records this as incomplete, allowing a later visit to retry.
      final text = await contentText(itemId);
      if (text.trim().isEmpty) throw const ApiException('正文为空');
      return ChapterContent.fromPlainText(text);
    }
  }

  /// Resolve a share URL to a book id.
  Future<Map<String, dynamic>> resolve(String url) async {
    final r = await _get(_url('/api/resolve', {'url': url}));
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
    final r = await _get(_homepageUrl(tabType, offset, sessionId));
    return _decodeAsync(r);
  }

  /// Homepage variant that combines envelope decoding, recursive card
  /// extraction and cursor scanning in a single isolate hop.
  Future<HomepagePage> homepagePage({
    int tabType = 2,
    int offset = 0,
    String? sessionId,
  }) async {
    final r = await _get(_homepageUrl(tabType, offset, sessionId));
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(() {
      final payload = _decodeEnvelope(statusCode, bodyBytes);
      int? nextOffset;
      String? nextSessionId;
      var selectedPayload = payload;
      final data = payload['data'];
      if (data is Map) {
        final tabItems = data['tab_item'];
        if (tabItems is List) {
          selectedPayload = <String, dynamic>{};
          for (final raw in tabItems) {
            if (raw is! Map || raw['tab_type']?.toString() != '$tabType') {
              continue;
            }
            selectedPayload = Map<String, dynamic>.from(raw);
            final candidate = raw['next_offset'];
            if (candidate is num &&
                candidate.toInt() > offset &&
                (nextOffset == null || candidate.toInt() > nextOffset)) {
              nextOffset = candidate.toInt();
            }
            final candidateSession = raw['session_id'];
            if (candidateSession is String && candidateSession.isNotEmpty) {
              nextSessionId = candidateSession;
            }
          }
        }
      }
      final items = parseMediaItems(
        selectedPayload,
        kind: tabType == 24 ? 'manju' : null,
      );
      return HomepagePage(
        items: items,
        nextOffset: nextOffset,
        sessionId: nextSessionId,
      );
    });
  }

  String _homepageUrl(int tabType, int offset, String? sessionId) =>
      _url('/api/v1/recommend/homepage', {
        'tab_type': '$tabType',
        'offset': '$offset',
        if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      });

  /// Health check.
  Future<bool> health() async {
    try {
      final r = await _get(
        '$_base/health',
        timeout: const Duration(seconds: 3),
      );
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

Map<String, dynamic> _decodeEnvelope(int statusCode, List<int> bodyBytes) {
  if (statusCode != 200) {
    throw ApiException('HTTP $statusCode', statusCode: statusCode);
  }
  final decoded = jsonDecode(utf8.decode(bodyBytes));
  if (decoded is! Map) throw ApiException('响应格式错误');
  final payload = Map<String, dynamic>.from(decoded);
  // The web bridge uses code=200; REST upstream-compatible endpoints use
  // code=0. Both are successful envelopes.
  if (payload['code'] != null &&
      payload['code'] != 200 &&
      payload['code'] != 0) {
    throw ApiException(
      '${payload['message'] ?? '请求失败'}',
      upstreamCode: payload['code'] is int ? payload['code'] as int : null,
    );
  }
  if (payload['success'] == false) {
    throw ApiException('${payload['error'] ?? payload['message'] ?? '请求失败'}');
  }
  return payload;
}

String _extractChapterText(Map<String, dynamic> payload) {
  String visit(dynamic value, [int depth = 0]) {
    if (depth > 7 || value == null) return '';
    if (value is Map) {
      for (final key in ['content', 'text', 'article_content', 'body']) {
        final candidate = value[key];
        if (candidate is String && candidate.trim().isNotEmpty) {
          return normalizeChapterText(candidate);
        }
      }
      for (final nested in value.values) {
        final result = visit(nested, depth + 1);
        if (result.isNotEmpty) return result;
      }
    } else if (value is List) {
      for (final nested in value) {
        final result = visit(nested, depth + 1);
        if (result.isNotEmpty) return result;
      }
    }
    return '';
  }

  return visit(payload);
}

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final int? upstreamCode;

  const ApiException(this.message, {this.statusCode, this.upstreamCode});

  @override
  String toString() => message;
}
