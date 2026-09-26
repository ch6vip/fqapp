import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/audio_extra.dart';
import '../models/author_profile.dart';
import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/chapter_ideas.dart';
import '../models/channel_tab.dart';
import '../models/chapter_media.dart';
import '../models/chapter_summary.dart';
import '../models/comment_reply.dart';
import '../models/media_item.dart';
import '../models/media_id.dart';
import '../models/playlet_comment.dart';
import '../models/rank.dart';
import '../models/search_discovery.dart';
import '../models/series_detail.dart';
import 'backend_service.dart';
import 'backend_transport.dart';
import 'chapter_text_formatter.dart';
import 'request_gate.dart';

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
    BackendTransport? transport,
    String? baseUrl,
    this._timeout = const Duration(seconds: 20),
    this._comicTimeout = const Duration(seconds: 90),
  }) : _transport =
           transport ??
           (client != null || baseUrl != null
               ? HttpBackendTransport(
                   client: client,
                   baseUrl: baseUrl ?? BackendService.instance.baseUrl,
                 )
               : BackendService.instance.transport);

  static final ApiClient instance = ApiClient();

  /// Per-instance gate: coalescing must not reach across test instances, and
  /// a restarted backend service gets a fresh flight table.
  final RequestGate _gate = RequestGate();

  /// Zone key carrying the [BackendRequest] a call belongs to.
  static final Object _requestZoneKey = Object();

  /// Binds every backend request started inside [body] to [request].
  ///
  /// The binding travels in the current Zone, so existing call sites keep their
  /// signatures while the request owner (a page, a feed loader) still controls
  /// cancellation: cancelling [request] aborts the in-flight Rust dispatch and
  /// the awaiting upstream call. This is the same mechanism
  /// `http.runWithClient` uses for test clients.
  Future<T> withCancellation<T>(
    BackendRequest request,
    Future<T> Function() body,
  ) {
    if (request.isCancelled) {
      return Future<T>.error(BackendRequestAborted('请求已取消'));
    }
    return runZoned(body, zoneValues: {_requestZoneKey: request});
  }

  /// Business calls go through the Rust core by default. Tests and the Web
  /// build inject an [http.Client]/base URL and get the loopback HTTP adapter,
  /// which shares the same Rust dispatcher.
  final BackendTransport _transport;

  /// 视频 tab（短剧 feed）的 cell id，按 tab_type 缓存：官方第二段
  /// `bookmall/cell/change` 必须带这个 tab 的 cell，而它只出现在第一段的响应里。
  /// 每个 tab 一个值，几天内都不会变；取不到时按老路径走，所以缓存过期只会
  /// 退化成第一段的结果。
  final Map<int, String> _seriesCellIds = {};

  /// Timeout applied to every backend request. The backend runs locally, so a
  /// healthy call returns in well under this; a hung child process or a stuck
  /// upstream request must not leave a page spinning forever.
  final Duration _timeout;

  // Encrypted comic chapters are downloaded and decrypted by the backend
  // before its JSON response is ready, so they need a separate finite limit.
  final Duration _comicTimeout;

  /// Base URL used to resolve backend-relative resources (`/src/...`). It is
  /// read from the transport so a backend restart cannot leave a stale port.
  String get _base => _transport.baseUrl;

  /// Converts a backend-relative resource (`/src/foo.mp4`) into a URL the
  /// Flutter networking plugins can consume. JSON API paths stay untouched.
  String absoluteUrl(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return raw;
    final parsed = Uri.tryParse(raw);
    if (parsed != null && parsed.hasScheme) {
      if ((parsed.scheme != 'http' && parsed.scheme != 'https') ||
          parsed.host.isEmpty) {
        return '';
      }
      return raw;
    }
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
  ///
  /// Every call passes through [RequestGate]: identical concurrent GETs share
  /// one upstream flight, and no more than sixteen talk to the core at once.
  Future<http.Response> _get(
    String url, {
    Duration? timeout,
    String method = 'GET',
    Uint8List? body,
  }) {
    // The transport owns the deadline: cancelling drops the in-flight Rust
    // dispatch (and therefore the upstream request, its retry backoff and any
    // pending write), so a late result can never be published.
    final request = Zone.current[_requestZoneKey];
    final effectiveTimeout = timeout ?? _timeout;
    return _gate.run(
      '$method $url ${effectiveTimeout.inMilliseconds}',
      request: request is BackendRequest ? request : null,
      share: method == 'GET' && body == null,
      send: () async {
        final response = await _transport.send(
          method,
          Uri.parse(url),
          body: body,
          timeout: effectiveTimeout,
          request: request is BackendRequest ? request : null,
        );
        return http.Response.bytes(
          response.body,
          response.statusCode,
          headers: response.contentType.isEmpty
              ? const {}
              : {'content-type': response.contentType},
        );
      },
    );
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

  /// Resolve the playable audio model for [itemId].
  ///
  /// A book ID is required: the `/api/content` speech bridge returns subtitles
  /// only (`speech_text`) and can never yield a playable URL (see
  /// docs/validation/native-media-api-validation-20260908.md), so silently
  /// querying it would fail with a misleading error.
  Future<AudioSource> audioSource(
    String itemId, {
    String? toneId,
    String? bookId,
  }) async {
    final trimmedBookId = bookId?.trim() ?? '';
    if (trimmedBookId.isEmpty) {
      throw ArgumentError.value(
        bookId,
        'bookId',
        'audioSource requires a book ID; the speech-text bridge does not '
            'return a playable audio URL',
      );
    }
    final selectedTone = toneId == null || toneId.trim().isEmpty
        ? '0'
        : toneId.trim();
    // The official single-chapter playback endpoint honours the requested
    // tone_id — the legacy video_model/mget bridge ignores it, which made
    // switching 智能朗读 a no-op. A pure-TTS book answers NO_THIS_TONE for
    // tone 0, so the caller falls back to the first selectable voice.
    final response = await _get(
      _url(
        '/api/v1/audio/books/${Uri.encodeComponent(trimmedBookId)}'
        '/chapters/${Uri.encodeComponent(itemId)}',
        {'tone_id': selectedTone},
      ),
    );
    final statusCode = response.statusCode;
    final bodyBytes = response.bodyBytes;
    final baseUrl = _base;
    return Isolate.run(() {
      final payload = _decodeEnvelope(statusCode, bodyBytes);
      try {
        return parsePlayinfoSource(
          payload,
          itemId: itemId,
          toneId: selectedTone,
          baseUrl: baseUrl,
        );
      } on FormatException catch (error) {
        // An upstream business error is final — do not fall through to the
        // legacy mget shape, which can never answer a playinfo payload.
        if (!error.message.contains('未获取到音频地址')) {
          throw ApiException(error.message);
        }
        return parseAudioSource(
          payload,
          itemId: itemId,
          toneId: selectedTone,
          baseUrl: baseUrl,
        );
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
      return await Isolate.run(() {
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
      return await Isolate.run(() {
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
  /// Note: `server_channel` must be **38**, not the 43 the official presenter
  /// assigns — see
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  ///
  /// This is the official client's paragraph-comment recipe, with one field
  /// corrected against live data. 43 (the decompiled presenter's value) is
  /// accepted (`code=0`) but always answers `total=0`. Channel 39 was the first
  /// fix — it matched the idea count on the two books verified then — but on
  /// other books (e.g. 7276384138653862966, 我不是戏神) it returns `total=0`
  /// while the idea list reports 77519. Channel **38** matches the idea count
  /// on every book tested, including those two, so it is the real paragraph
  /// channel and 39 was a partial mirror.
  ///
  /// The container is the **chapter item id** while `business_param.book_id`
  /// stays the real book id. All three of `book_id`, [itemVersion] and
  /// [paraIndex] are required: the upstream rejects the request with
  /// `103001 book_id, item_version, or para_index invalid` unless each is usable.
  Future<BookCommentPage> paragraphComments(
    String bookId,
    String itemId, {
    required String itemVersion,
    required int paraIndex,
    int count = 20,
    String? cursor,
  }) async {
    // Old saved catalogues have no version. Refresh it on demand instead of
    // turning a paragraph with a nonzero bubble count into an empty page.
    var version = itemVersion.trim();
    if (version.isEmpty) {
      final volumes = await directoryChapters(bookId);
      for (final chapter in volumes.expand((volume) => volume)) {
        if (chapter.itemId == itemId) {
          version = chapter.version.trim();
          break;
        }
      }
      if (version.isEmpty) {
        throw const ApiException('章节信息暂时无法加载');
      }
    }
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/reviews', {
        'book_id': bookId,
        'group_id': itemId,
        'group_type': '15',
        'comment_source': '2',
        'comment_type': '1',
        // 38 is the paragraph-comment channel that matches the idea count on
        // every book tested. 43 (the official presenter's value) is accepted
        // but always yields an empty list; 39 matched only some books.
        'server_channel': '38',
        'para_index': '$paraIndex',
        'item_version': version,
        'count': '$count',
        // Pagination token: the numeric `common_list_info.cursor` of the
        // previous page. Omitted on the first request so it stays byte for
        // byte identical with the verified recipe.
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
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
      return await Isolate.run(
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
      return await Isolate.run(
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
      return await Isolate.run(
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
      return await Isolate.run(
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

  /// 短剧剧评（官方 `gx1/m.java:168-181`）：`:group_id` 是剧集 id。
  ///
  /// [sort] 1=最热（「全部」）、3=最新；[tag] 是服务端筛选标签，
  /// 非空时官方同时改用最新排序。
  Future<PlayletCommentPage> playletComments(
    String seriesId, {
    int sort = UgcSort.smartHot,
    int count = 10,
    String cursor = '',
    String tag = '',
    String insertCommentIds = '',
  }) async {
    final response = await _get(
      _url('/api/v1/series/${Uri.encodeComponent(seriesId)}/comments', {
        'sort': '$sort',
        'count': '$count',
        if (cursor.isNotEmpty) 'cursor': cursor,
        if (tag.isNotEmpty) 'tag': tag,
        // 官方从热评进入时把它插进列表（`gx1/m.java:236-241`）。
        if (insertCommentIds.isNotEmpty) 'insert_comment_ids': insertCommentIds,
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => PlayletCommentPage.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// 短剧回复读取使用 Book/NovelBookReply 参数，不能走小说段评回复接口。
  Future<CommentReplyPage> playletCommentReplies(
    String seriesId,
    String commentId, {
    int count = 10,
    String cursor = '',
  }) async {
    final response = await _get(
      _url(
        '/api/v1/series/${Uri.encodeComponent(seriesId)}/comments/'
        '${Uri.encodeComponent(commentId)}/replies',
        {'count': '$count', if (cursor.isNotEmpty) 'cursor': cursor},
      ),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => CommentReplyPage.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// 短剧弹幕取数（官方 `DanmakuRequestHelper.java:314-329`）。
  ///
  /// [vid] 是当前视频 id（官方把它当 path 的 group_id），[seriesId] 进
  /// `business_param.book_id`；时间单位是毫秒。
  Future<PlayletCommentPage> playletDanmaku(
    String vid, {
    required String seriesId,
    int startOffsetMs = 0,
    Duration duration = Duration.zero,
    String cursor = '',
  }) async {
    final response = await _get(
      _url('/api/v1/videos/${Uri.encodeComponent(vid)}/danmaku', {
        'series_id': seriesId,
        'start_offset_time': '$startOffsetMs',
        'playlet_item_duration': '${duration.inSeconds}',
        if (cursor.isNotEmpty) 'cursor': cursor,
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () =>
          PlayletCommentPage.fromDanmakuPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// 官方热评 + 右栏评论计数（`a13/w.java:563-599`）。
  ///
  /// 热评与剧评共用一条列表接口，这里固定 `comment_source=4`、
  /// `comment_type=4`、`group_type=30`、`count=20`；返回
  /// `common_list_info.total` 就是右栏评论计数，列表则由 [hotOf] 在本地筛。
  ///
  /// [vid] 为空时退化成剧集 id（官方 `jVar.C()` 的书场景分支）。
  Future<PlayletCommentPage> playletHotComments(
    String seriesId, {
    String vid = '',
    int serverChannel = 17,
  }) async {
    final response = await _get(
      _url('/api/v1/series/${Uri.encodeComponent(seriesId)}/hot-comments', {
        if (vid.isNotEmpty) 'vid': vid,
        'server_channel': '$serverChannel',
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => PlayletCommentPage.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// 发短剧评论（官方 `comment/add`，`community/.../playlet/editor/p0.java:211-256`）。
  ///
  /// [dataType] 官方由调用点给：列表页普通具评用 `Book(2)`，
  /// 快捷评星用 `FakeBook(3)`（`kr1/n.java:241`）。
  Future<void> addPlayletComment(
    String seriesId,
    String text, {
    int dataType = 2,
    int score = 0,
  }) async {
    final response = await _get(
      _url('/api/v1/series/${Uri.encodeComponent(seriesId)}/comments/add', {
        'text': text,
        'data_type': '$dataType',
        'score': '$score',
      }),
      method: 'POST',
    );
    _checkWrite(response);
  }

  /// 发弹幕（官方 `hy1/l.java:86-113`）：`group_id` 是 vid，时间毫秒。
  Future<void> addPlayletDanmaku(
    String vid, {
    required String seriesId,
    required String text,
    required int offsetMs,
  }) async {
    final response = await _get(
      _url('/api/v1/videos/${Uri.encodeComponent(vid)}/danmaku/add', {
        'text': text,
        'series_id': seriesId,
        'offset': '$offsetMs',
      }),
      method: 'POST',
    );
    _checkWrite(response);
  }

  /// 回复短剧评论（官方 `nx1/d.java:217-231`）。
  Future<void> replyPlayletComment(
    String commentId, {
    required String seriesId,
    required String text,
    String replyToReplyId = '',
    String replyToUserId = '',
  }) async {
    final response = await _get(
      _url('/api/v1/comments/${Uri.encodeComponent(commentId)}/reply', {
        'text': text,
        'series_id': seriesId,
        if (replyToReplyId.isNotEmpty) 'reply_to_reply_id': replyToReplyId,
        if (replyToUserId.isNotEmpty) 'reply_to_user_id': replyToUserId,
      }),
      method: 'POST',
    );
    _checkWrite(response);
  }

  /// 点赞/取消点赞短剧评论（官方独立 digg 接口，`social/t.java:803-831`）。
  ///
  /// [targetType] 官方 `DiggTargetType`：Comment=1 / Reply=2 / PlayletComment=5；
  /// 短剧评论该用哪个**未取证**，所以由调用方给。
  Future<void> diggPlayletComment(
    String commentId, {
    required bool liked,
    String bookId = '',
    int targetType = 1,
  }) async {
    final response = await _get(
      _url('/api/v1/comments/${Uri.encodeComponent(commentId)}/digg', {
        'liked': liked ? 'true' : 'false',
        'target_type': '$targetType',
        if (bookId.isNotEmpty) 'book_id': bookId,
      }),
      method: 'POST',
    );
    _checkWrite(response);
  }

  /// 写接口的业务码检查：HTTP 200 里也会带回业务错误，不能只看状态码。
  /// 与只读接口一致，把上游带出来的业务码放进 `upstreamCode`。
  void _checkWrite(http.Response response) {
    final status = response.statusCode;
    if (status != 200) {
      throw ApiException('写入失败', statusCode: status);
    }
    final payload = jsonDecode(utf8.decode(response.bodyBytes));
    if (payload is! Map) return;
    final code = payload['code'];
    if (code == null || code == 0 || code == 200) return;
    throw ApiException(
      '${payload['message'] ?? '写入失败'}',
      statusCode: status,
      upstreamCode: code is int ? code : int.tryParse('$code'),
    );
  }

  /// 短剧分享信息（官方 `m0.java:930-957`，`share_type=7`）。
  ///
  /// 官方的 `share_url`/`short_url`/`schema` 全部由服务端下发，客户端不下发
  /// 字面量，所以这里只回传原始 JSON 供页面取字段。
  Future<Map<String, dynamic>> playletShare(
    String seriesId, {
    String currentChapterId = '',
    String firstChapterId = '',
    String shareTimestamp = '',
    String entrance = '',
  }) async {
    final response = await _get(
      _url('/api/v1/series/${Uri.encodeComponent(seriesId)}/share', {
        if (currentChapterId.isNotEmpty) 'current_chapter_id': currentChapterId,
        if (firstChapterId.isNotEmpty) 'first_chapter_id': firstChapterId,
        if (shareTimestamp.isNotEmpty) 'share_timestamp': shareTimestamp,
        if (entrance.isNotEmpty) 'entrance': entrance,
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(() => _decodeEnvelope(status, bytes));
  }

  /// 复制链接的短链兜底（官方 `LinkShareItem.java:86-104` 的
  /// `GET /reading/user/share/short_url/`）。失败由调用方回落长链。
  Future<String> shareShortUrl(String target) async {
    final response = await _get(
      _url('/api/v1/share/short-url', {'target': target}),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    final payload = await Isolate.run(() => _decodeEnvelope(status, bytes));
    final data = payload['data'];
    if (data is String) return data.trim();
    if (data is Map && data['short_url'] != null) {
      return '${data['short_url']}'.trim();
    }
    return '';
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
      return await Isolate.run(
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
  Future<String> contentText(
    String itemId, {
    String tab = '小说',
    Duration? timeout,
  }) async {
    final r = await _get(_contentUrl(itemId, tab: tab), timeout: timeout);
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
    final stopwatch = Stopwatch()..start();
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
      // A slow illustrated answer must not stack a second full timeout on top:
      // the fallback inherits the remaining budget (floored so a fast failure
      // still gets a real attempt), keeping the worst case near one timeout
      // instead of two.
      final remaining = _timeout - stopwatch.elapsed;
      final text = await contentText(
        itemId,
        timeout: remaining > const Duration(seconds: 5)
            ? remaining
            : const Duration(seconds: 5),
      );
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
  ///
  /// 官方短剧 feed 是**两段**：`/reading/bookapi/bookmall/tab` 只给出这个 tab 的
  /// cell（`cell_id_str`）和 session，视频流本身由
  /// `/reading/bookapi/bookmall/cell/change` 返回
  /// （`com/dragon/read/shortvideo/common/c.java`）。所以视频 tab 在第一段之后
  /// 追加第二段；第二段拿不到就退回第一段的结果，老后端没有第二段时行为不变。
  Future<HomepagePage> homepagePage({
    int tabType = 2,
    int offset = 0,
    String? sessionId,
  }) async {
    // 翻页时第一段只是用来开 cell 的：它的游标和视频流不是一回事，而且把第二段
    // 的 session 再传给 tab 接口会被上游拒掉（客户端表现为 SERVICE_ERROR）。所以
    // 已经知道 cell 的翻页直接打第二段。
    final cachedCellId = _seriesCellIds[tabType];
    if (offset > 0 &&
        cachedCellId != null &&
        cachedCellId.isNotEmpty &&
        _seriesFlowTabs.contains(tabType)) {
      final flow = await _seriesFlowPage(
        tabType: tabType,
        cellId: cachedCellId,
        offset: offset,
        sessionId: sessionId,
      );
      if (flow != null) return flow;
    }
    final r = await _get(_homepageUrl(tabType, offset, sessionId));
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    final tab = await Isolate.run(() {
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
      return (
        page: HomepagePage(
          items: items,
          nextOffset: nextOffset,
          sessionId: nextSessionId,
        ),
        // 数字型 `cell_id` 在 JSON 里是 double，会被精度截断成上游认不出的值，
        // 必须取 `cell_id_str`。
        cellId: _firstStringField(payload, 'cell_id_str'),
      );
    });
    if (!_seriesFlowTabs.contains(tabType)) return tab.page;
    // 翻页时上面已经拿第二段试过一次（同一个参数），失败就别再打一遍。
    if (offset > 0 && cachedCellId != null && cachedCellId.isNotEmpty) {
      return tab.page;
    }
    final cellId = tab.cellId ?? _seriesCellIds[tabType];
    if (cellId == null || cellId.isEmpty) return tab.page;
    _seriesCellIds[tabType] = cellId;
    final flow = await _seriesFlowPage(
      tabType: tabType,
      cellId: cellId,
      offset: offset,
      // 第一段刚开的 session 一并带上：后端据此把第二段钉在同一台设备上
      // （上游否则回 101116）。
      sessionId: sessionId ?? tab.page.sessionId,
    );
    return flow ?? tab.page;
  }

  /// 走官方第二段（`bookmall/cell/change`）拉视频流；任何失败都返回 null，
  /// 由调用方退回第一段。
  Future<HomepagePage?> _seriesFlowPage({
    required int tabType,
    required String cellId,
    required int offset,
    String? sessionId,
  }) async {
    try {
      final url = _seriesFlowUrl(
        tabType: tabType,
        cellId: cellId,
        offset: offset,
        sessionId: sessionId,
      );
      final r = await _get(url);
      final statusCode = r.statusCode;
      final bodyBytes = r.bodyBytes;
      return await Isolate.run(() {
        final payload = _decodeEnvelope(statusCode, bodyBytes);
        final items = parseMediaItems(
          payload,
          kind: tabType == 24 ? 'manju' : 'video',
        );
        if (items.isEmpty) return null;
        int? nextOffset;
        String? nextSessionId;
        final data = payload['data'];
        if (data is Map) {
          final candidate = data['next_offset'];
          if (candidate is num && candidate.toInt() > offset) {
            nextOffset = candidate.toInt();
          }
          final candidateSession = data['session_id'];
          if (candidateSession is String && candidateSession.isNotEmpty) {
            nextSessionId = candidateSession;
          }
        }
        return HomepagePage(
          items: items,
          nextOffset: nextOffset,
          sessionId: nextSessionId,
        );
      });
    } catch (error) {
      // 第二段是可选增强：失败就退回第一段。但静默吞掉异常会让「为什么没生效」
      // 变成谜案，所以测试里把它打出来（release 由 assert 去掉）。
      assert(() {
        // ignore: avoid_print
        print('[series-feed] failed: $error');
        return true;
      }());
      return null;
    }
  }

  String _seriesFlowUrl({
    required int tabType,
    required String cellId,
    required int offset,
    String? sessionId,
  }) => _url('/api/v1/recommend/series-feed', {
    'cell_id': cellId,
    'tab_type': '$tabType',
    'client_template': '2',
    'client_req_type': '2',
    'offset': '$offset',
    // 首屏 ChangeFilter(2)，翻页 GetMore(1)：官方 `c.java` 的 q()/m() 两个分支。
    'unlimited_selector_change_type': offset > 0 ? '1' : '2',
    if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
  });

  /// 服务端频道表（F08）：官方 `GET /reading/bookapi/bookmall/tab/v`
  /// 的 `data.tab_item`（`TabDataList.tabItem`），客户端在 `m0.java:3051-3089`
  /// 把 `title` 当频道名、`tab_type` 当类型。失败/空表返回空列表，
  /// 由调用方回落到既有频道表。
  Future<List<ChannelTab>> channelTabs({int tabType = 16}) async {
    try {
      final r = await _get(
        _url('/api/v1/recommend/channels', {'tab_type': '$tabType'}),
      );
      final statusCode = r.statusCode;
      final bodyBytes = r.bodyBytes;
      return await Isolate.run(() {
        try {
          final payload = _decodeEnvelope(statusCode, bodyBytes);
          return ChannelTab.listFromPayload(payload);
        } catch (_) {
          return const <ChannelTab>[];
        }
      });
    } catch (_) {
      return const <ChannelTab>[];
    }
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

String? _errorMessageFromBody(List<int> bodyBytes) {
  if (bodyBytes.isEmpty) return null;
  try {
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    if (decoded is Map) {
      final payload = Map<String, dynamic>.from(decoded);
      for (final key in ['error', 'message']) {
        final value = payload[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    }
  } catch (_) {
    // Not a JSON error envelope; keep the HTTP status as the message.
  }
  return null;
}

Map<String, dynamic> _decodeEnvelope(int statusCode, List<int> bodyBytes) {
  if (statusCode != 200) {
    throw ApiException(
      _errorMessageFromBody(bodyBytes) ?? 'HTTP $statusCode',
      statusCode: statusCode,
    );
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

/// 递归找第一个非空的字符串字段。官方 feed 的 cell id 藏在深层 cell 里，且
/// 数字写法会丢精度，只能按名字取字符串值。
String? _firstStringField(dynamic node, String key, [int depth = 0]) {
  if (depth > 16 || node == null) return null;
  if (node is Iterable) {
    for (final child in node) {
      final found = _firstStringField(child, key, depth + 1);
      if (found != null) return found;
    }
    return null;
  }
  if (node is! Map) return null;
  final value = node[key];
  if (value is String && value.isNotEmpty) return value;
  if (value != null && value is num) return value.toString();
  for (final child in node.values) {
    final found = _firstStringField(child, key, depth + 1);
    if (found != null) return found;
  }
  return null;
}

/// 短剧 feed 里走官方第二段（`bookmall/cell/change`）的频道：推荐 16 / 看剧 8 / 漫剧 24。
///
/// 推荐频道尤其需要第二段：第一段只回 2 张卡且没有翻页游标，第二段回 5 张并给出游标
/// （实测 `series_title`/`video_data` 计数 2→5）。它的卡是模板卡（`show_type=407`），
/// 标题/封面走 `series_title`/`series_cover` 而不是 `title`/`cover`，且精确的系列 id
/// 在 `series_id_str`（数字型 `series_id` 已被上游截断）—— 这三处映射在
/// `models/media_item.dart` 的 `MediaItem.fromRaw` 里处理。
const _seriesFlowTabs = {8, 16, 24};
