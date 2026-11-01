part of 'player_page.dart';

/// 播放页的「提前准备下一集」：边看边缓存、快播完时预热下一集的播放器、
/// 起播失败后的静默重试与取流。
///
/// 从 `player_page.dart` 挪进 part 文件，避免主文件继续超过行数预算；
/// 同库扩展仍是 `_PlayerPageState` 的方法。
extension _PlayerPagePreload on _PlayerPageState {
  /// 边看边往后缓存：这一集出画面后，把后面几集排进离线下载队列，
  /// 断网 / 信号差的时候也能接着看。
  ///
  /// 与小说阅读时预取前后各一章同构，区别是短剧一集几十 MB，所以默认
  /// 限 Wi-Fi、限 5 集，并且只保留最近的一段（见 [_trimAutoCache]）。
  /// 用户手动下载的一律不碰：那批记录的 `auto` 是 false。
  void _scheduleAutoCache(NativePlayer player) {
    if (!widget.shortSeries || widget.bookId.isEmpty) return;
    if (_autoCacheFor == _index) return;
    // 同一集的首帧会来好几次（起播、换流、重试），别每次都把 2 秒推后。
    if (_autoCacheTimer != null && _autoCacheTimerIndex == _index) return;
    _autoCacheTimer?.cancel();
    _autoCacheTimerIndex = _index;
    _autoCacheTimer = Timer(const Duration(seconds: 2), () {
      _autoCacheTimer = null;
      _autoCacheTimerIndex = null;
      // 判活用播放器实例而不是 generation：换流重试会让 generation 递增，
      // 拿旧的 generation 判会把这一集的预缓存白白放弃掉。
      if (!mounted || !identical(player, _player)) return;
      if (_autoCacheFor == _index) return;
      unawaited(_autoCacheNext());
    });
  }

  /// 当前实际在播的清晰度（像素高度），取不到返回 null。
  ///
  /// 优先用选档时记下的高度：`variants` 里可能有两条 url 相同、高度不同的
  /// 别名流，按 url 反查只会拿到第一条，不一定是正在播的那条。没选过档时看
  /// 播放器解码出来的高度——播的是上游默认流时，它到底绑到哪一档客户端并不
  /// 知道，但解码后就有答案了。两者都取不到才退回按 url 认领。
  int? _playingHeight() {
    final selected = _renditionHeight;
    if (selected != null) return selected;
    final decoded = _player?.videoHeight ?? 0;
    if (decoded > 0) return decoded;
    final source = _currentSource;
    if (source == null) return null;
    for (final variant in source.variants) {
      if (variant.url != source.url) continue;
      return variant.height > 0 ? variant.height : null;
    }
    return null;
  }

  Future<void> _autoCacheNext() async {
    final index = _index;
    final prefs = DramaCachePreferences.instance;
    final ahead = prefs.ahead.value;
    if (ahead <= 0) return;
    final upcoming = autoCacheEpisodes(
      episodes: widget.eps,
      currentIndex: index,
      ahead: ahead,
    );
    if (upcoming.isEmpty) return;
    // store 未就绪（Hive 未初始化的测试环境）直接跳过，别碰 openBox。
    if (!_downloadStore.isReady) return;
    if (prefs.wifiOnly.value) {
      // 测不出网络形态时按「不是 Wi-Fi」处理：自动缓存没有流量确认兜底。
      final view = await probeConnectivity();
      if (view == null || !view.online || view.metered) return;
    }
    if (!mounted) return;
    try {
      await _downloader.enqueue(
        drama: CachedDrama(
          id: widget.bookId,
          title: _seriesTitle,
          cover: widget.cover,
          episodes: widget.eps,
        ),
        episodes: upcoming,
        auto: true,
        // 用户在面板里挑过画质就守那个上限；没挑过就跟**当前正在播的这一档**
        // 保持一致 —— 播放器已经按网速/清晰度选过一次了，自动缓存再自作
        // 主张挑最高档，只会让流量和空间白涨。
        maxHeight: prefs.downloadHeight.value != 0
            ? prefs.downloadHeight.value
            : _playingHeight(),
      );
      // 排上了才算这一集处理过：上面每条早退都不算，否则那一集永远没
      // 机会再自动缓存（冷启动 store 未就绪、或在移动网络下起播都会）。
      _autoCacheFor = index;
      await _trimAutoCache(ahead);
    } catch (_) {
      // 预缓存是机会性的：失败（权限、空间、解析不到地址）不能影响播放，
      // 也不打扰用户 —— 用户手动缓存时才会看到具体错误。
    }
  }

  /// 跟着播放进度丢掉自动缓存的旧集，只留「当前集之前 2×ahead」以后的。
  ///
  /// 只删 `auto == true` 的记录 —— 用户在缓存面板里手动下的集永远不动。
  Future<void> _trimAutoCache(int ahead) async {
    final cutoff = _index - ahead * 2;
    if (cutoff <= 0) return;
    final store = _downloadStore;
    try {
      final summaries = await store.dramas();
      for (final summary in summaries) {
        if (summary.drama.id != widget.bookId) continue;
        // 集记录里的 index 是「入队时的相对序号」，不能当全集位置用；
        // 目录 `drama.episodes` 的顺序才是权威的。
        final order = {
          for (final (position, episode) in summary.drama.episodes.indexed)
            episode.itemId: position,
        };
        for (final episode in summary.episodes) {
          if (!episode.auto) continue;
          final position = order[episode.itemId];
          if (position == null || position >= cutoff) continue;
          await store.removeEpisode(episode.itemId);
        }
      }
    } catch (_) {
      // 清理失败只影响磁盘占用，不影响播放与已缓存内容的可用性。
    }
  }

  /// 剩这么多时开始预热下一集：够把地址、媒体头和开头几秒缓冲好，
  /// 又不会早到让签名地址在预热的播放器里过期。
  static const _warmLead = Duration(seconds: 30);

  /// 当前集快播完时，在后台把下一集的播放器建好：取地址、打开媒体、
  /// 暂停着缓冲，不上屏。自然播完或点「下一集」时 [_loadVideo] 直接接管
  /// 它，省掉取地址和 create 两段等待。只预热紧挨着的一集，最多一个。
  void _updateWarmNext() {
    final player = _player;
    if (player == null || !_canPrefetch(_loadGeneration, player)) return;
    final next = widget.eps[_index + 1];
    if (_warm?.itemId == next.itemId) return;
    final total = player.duration;
    if (total <= Duration.zero || total - player.position > _warmLead) return;
    _dropWarm();
    final warm = _warm = _WarmEpisode(
      next.itemId,
      widget.playerFactory?.call() ?? NativePlayer(),
    );
    // 不在播放器自己的事件回调里销毁它。
    warm.errors = warm.player.errorStream.listen(
      (_) => scheduleMicrotask(() => _discardWarm(warm)),
    );
    warm.ready = () async {
      try {
        final (source, height) = await _episodeSource(next);
        if (warm.dropped) return false;
        warm.source = source;
        warm.renditionHeight = height;
        await warm.player.create(source.url, source.keyHex);
        return !warm.dropped && warm.player.lastError == null;
      } catch (_) {
        return false;
      }
    }();
    unawaited(
      warm.ready.then((ok) {
        if (!ok) _discardWarm(warm);
      }),
    );
  }

  /// 预热失败是静默的：丢掉播放器和它用过的地址，切到这一集时按常规
  /// 链路重新取流（失败了还有 [_retrySilently] 兜底）。
  void _discardWarm(_WarmEpisode warm) {
    if (!identical(_warm, warm)) return;
    _sources.invalidate(warm.itemId);
    _dropWarm();
  }

  void _dropWarm() {
    final warm = _warm;
    if (warm == null) return;
    _warm = null;
    warm.dropped = true;
    unawaited(warm.errors?.cancel());
    // 和换集释放的播放器排在同一条队列里：新会话总在旧解码器释放后才建。
    _releases = Future.wait([
      _releases,
      warm.player.dispose(),
    ]).then<void>((_) {}).catchError((Object _) {});
  }

  /// 把 [itemId] 的预热播放器交给 [_loadVideo]；其他集的预热一律作废。
  _WarmEpisode? _takeWarm(String itemId) {
    final warm = _warm;
    if (warm == null || warm.itemId != itemId) {
      _dropWarm();
      return null;
    }
    _warm = null;
    unawaited(warm.errors?.cancel());
    return warm;
  }

  /// 还没出过画面的这一集失败时先静默重来，加载封面不撤：第一次换新地址，
  /// 第二次再换一档清晰度。CDN 偶发卡住、某一档流坏掉时，用户只是多等
  /// 一会儿，看不到「播放失败」。已经在播的集中途出错不在这里重来：那时
  /// 续播点还在异步落盘，重建会从旧进度开始。返回 true 表示已接手。
  bool _retrySilently() {
    if (_silentRetriesLeft <= 0 ||
        DateTime.now().isAfter(_silentRetryUntil) ||
        _hasDisplayed ||
        _switchingSeries ||
        !mounted) {
      return false;
    }
    final second = _silentRetriesLeft == 1;
    _silentRetriesLeft--;
    unawaited(
      _loadVideo(
        refresh: true,
        autoplay: _lastAutoplay,
        silent: true,
        avoidVariant: second ? _currentVariantName() : null,
      ),
    );
    return true;
  }

  /// 当前地址对应的清晰度名；播的是上游默认流且不在档位表里时为 null。
  String? _currentVariantName() {
    final source = _currentSource;
    if (source == null) return null;
    for (final variant in source.variants) {
      if (variant.url == source.url) return variant.name;
    }
    return null;
  }

  /// 本集要播的地址：离线优先（官方 isOfflineVideo 语义），已缓存的集直接
  /// 读本地加密文件，文件被清掉时回退在线。在线时套用会话内记住的画质；
  /// [avoidVariant] 是刚失败的一档，换到相邻一档。返回地址与选中档位的高度。
  Future<(EpisodeSource, int?)> _episodeSource(
    Chapter episode, {
    bool refresh = false,
    String? avoidVariant,
    PlayerLoadTrace? trace,
  }) async {
    final offline = await _offlineSource(episode);
    if (offline != null) {
      trace?.source = 'offline';
      return (offline, null);
    }
    final request = _sources.request(episode, refresh: refresh);
    trace?.source = request.origin.name;
    var online = await request.future;
    int? height;
    // 会话内记住的画质选择（官方=引擎当前档）：按画质名在本集自己
    // 的 variants 里找，找到就用，找不到回默认（#60：换下一集不
    // 应变回默认画质）。记忆由 [QualityMemory] 在 Feed 与播放页
    // 之间共享；只记名、不搬 variant 对象——variant 的 URL 属于
    // 它自己的集，搬过来会播错集的流。
    final chosenName = QualityMemory.nameFor(widget.bookId);
    if (chosenName != null) {
      for (final variant in online.variants) {
        if (variant.name == chosenName) {
          online = online.withVariant(variant);
          height = variant.height > 0 ? variant.height : null;
          break;
        }
      }
    }
    // 换档只为这一次起播，不写进 [QualityMemory]。
    if (avoidVariant != null) {
      if (fallbackVariant(online.variants, avoidVariant) case final variant?) {
        online = online.withVariant(variant);
        height = variant.height > 0 ? variant.height : null;
      }
    }
    return (online, height);
  }
}

class _WarmEpisode {
  _WarmEpisode(this.itemId, this.player);

  final String itemId;
  final NativePlayer player;
  EpisodeSource? source;
  int? renditionHeight;

  /// create 走完：true = 可以接管。
  late final Future<bool> ready;
  StreamSubscription<Object>? errors;

  /// 已作废（换集、换档、离开页面），还在路上的预热步骤不再继续。
  bool dropped = false;
}
