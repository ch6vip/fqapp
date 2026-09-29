import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/media_item.dart';
import 'episode_source_cache.dart';

/// 一集的离线缓存记录。文件是**原始 CENC 加密字节**（与官方加密落盘同
/// 姿态），keyHex 是该集确定性派生的内容密钥——回放时把 `file://` 路径
/// 和 key 一起交给原生播放器，解密仍发生在 C 核心流层，磁盘上永远没有
/// 明文。
@immutable
class CachedEpisode {
  const CachedEpisode({
    required this.seriesId,
    required this.itemId,
    required this.title,
    required this.index,
    required this.keyHex,
    required this.height,
    required this.variantName,
    required this.bytes,
    required this.filePath,
    required this.cachedAt,
  });

  final String seriesId;
  final String itemId;
  final String title;
  final int index;

  /// 该集该画质档的 16 字节内容密钥（hex），`spade_a` 的确定性派生，
  /// 不随会话变化。
  final String keyHex;
  final int height;
  final String variantName;

  /// 加密字节数（完成时实测的文件大小）。
  final int bytes;
  final String filePath;
  final int cachedAt;

  Map<String, dynamic> toMap() => {
    'seriesId': seriesId,
    'itemId': itemId,
    'title': title,
    'index': index,
    'keyHex': keyHex,
    'height': height,
    'variantName': variantName,
    'bytes': bytes,
    'filePath': filePath,
    'cachedAt': cachedAt,
  };

  static CachedEpisode? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final seriesId = raw['seriesId'];
    final itemId = raw['itemId'];
    final keyHex = raw['keyHex'];
    final filePath = raw['filePath'];
    if (seriesId is! String ||
        seriesId.isEmpty ||
        itemId is! String ||
        itemId.isEmpty ||
        keyHex is! String ||
        filePath is! String ||
        filePath.isEmpty) {
      return null;
    }
    return CachedEpisode(
      seriesId: seriesId,
      itemId: itemId,
      title: raw['title']?.toString() ?? '',
      index: raw['index'] is num ? (raw['index'] as num).toInt() : 0,
      keyHex: keyHex,
      height: raw['height'] is num ? (raw['height'] as num).toInt() : 0,
      variantName: raw['variantName']?.toString() ?? '',
      bytes: raw['bytes'] is num ? (raw['bytes'] as num).toInt() : 0,
      filePath: filePath,
      cachedAt: raw['cachedAt'] is num ? (raw['cachedAt'] as num).toInt() : 0,
    );
  }

  /// 离线回放的取流结果：主 url 是 `file://` 标记（原生播放器据此走
  /// 本地文件桥 + 同一把 key 解密），variants 只带下载时选定的那一档。
  EpisodeSource toSource() => EpisodeSource(
    'file://$filePath',
    keyHex,
    [
      if (variantName.isNotEmpty)
        EpisodeVariant(
          name: variantName,
          url: 'file://$filePath',
          keyHex: keyHex,
          height: height,
        ),
    ],
  );
}

/// 一部剧的目录（剧名/封面/全集列表），下载启动时落库，管理页靠它自举，
/// 不依赖任何页面传元数据。
@immutable
class CachedDrama {
  CachedDrama({
    required this.id,
    required this.title,
    required this.cover,
    required List<Chapter> episodes,
  }) : episodes = List.unmodifiable(episodes);

  final String id;
  final String title;
  final String cover;
  final List<Chapter> episodes;

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'cover': cover,
    'episodes': [
      for (final (index, episode) in episodes.indexed)
        {'itemId': episode.itemId, 'title': episode.title, 'index': index},
    ],
  };

  static CachedDrama? fromMap(dynamic raw) {
    if (raw is! Map || raw['id'] is! String || raw['episodes'] is! List) {
      return null;
    }
    final episodes = <Chapter>[];
    for (final value in raw['episodes'] as List) {
      if (value is! Map || value['itemId'] is! String) continue;
      episodes.add(
        Chapter(
          itemId: value['itemId'] as String,
          title: value['title']?.toString() ?? '',
          volumeName: '',
        ),
      );
    }
    if (episodes.isEmpty) return null;
    return CachedDrama(
      id: raw['id'] as String,
      title: raw['title']?.toString() ?? '未知剧集',
      cover: raw['cover']?.toString() ?? '',
      episodes: episodes,
    );
  }
}

/// 管理页的按剧聚合视图。
@immutable
class CachedDramaSummary {
  final CachedDrama drama;
  final List<CachedEpisode> episodes;

  const CachedDramaSummary(this.drama, this.episodes);

  int get bytes => episodes.fold(0, (sum, episode) => sum + episode.bytes);
}

abstract interface class DramaDownloadStore {
  /// 下载启动时写入/刷新剧集目录。
  Future<void> ensureCatalogue(CachedDrama drama);

  /// 完成一集：记录 + 刷新目录访问时间。
  Future<void> saveEpisode(CachedEpisode episode);

  Future<bool> isDownloaded(String itemId);
  Future<CachedEpisode?> episode(String itemId);

  /// 该集是否已有目录记录（管理页里「下载中」的剧）。
  Future<bool> hasCatalogue(String seriesId);

  Future<List<CachedDramaSummary>> dramas();
  Future<int> totalBytes();
  Future<void> removeEpisode(String itemId);
  Future<void> removeDrama(String seriesId);

  /// 视频文件目录（不存在则创建）。
  Future<Directory> directory();

  ValueListenable<int> get changes;
}

class HiveDramaDownloadStore implements DramaDownloadStore {
  HiveDramaDownloadStore({
    HiveInterface? hive,
    Future<Directory> Function()? directoryResolver,
  }) : _hive = hive ?? Hive,
       _dirResolver = directoryResolver;

  static final HiveDramaDownloadStore instance = HiveDramaDownloadStore();
  static const _boxName = 'drama_download_v1';


  /// box 是否已打开。播放器的离线命中读路径用它做前置门：Hive 未初始化
  /// 时触碰 openBox 会产生无法被 try/catch 完全拦住的异步错误（openBox
  /// 内部 completer 的孪生错误），生产环境由 main 的 [warmUp] 打开。
  bool get isReady => _hive.isBoxOpen(_boxName);

  /// 启动时打开 box；失败不拖启动（离线命中退化为每次都走在线）。
  Future<void> warmUp() async {
    try {
      await _box();
    } catch (_) {
      _opening = null;
    }
  }

  final HiveInterface _hive;
  final Future<Directory> Function()? _dirResolver;
  Directory? _dir;

  @override
  final ValueNotifier<int> changes = ValueNotifier(0);
  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();

  Future<Box<dynamic>> _box() async {
    // Hive.close()（全量关箱，测试 tearDown 的常态）之后 openBox 仍会把
    // 注册表里的已关闭实例交回来——按「已开直接取、未开才开」收口，
    // 不做「拿到关闭箱就重试」的递归（那会无限循环）。
    if (_hive.isBoxOpen(_boxName)) return _hive.box(_boxName);
    final opening = _opening ??= _hive.openBox<dynamic>(_boxName);
    try {
      return await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  Future<T> _serialize<T>(Future<T> Function(Box<dynamic>) action) {
    final operation = _writes.then((_) async => action(await _box()));
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _) {
        _opening = null;
      },
    );
    return operation;
  }

  @override
  Future<Directory> directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    final root = await (_dirResolver?.call() ?? getApplicationSupportDirectory());
    final dir = Directory('${root.path}${Platform.pathSeparator}offline-video');
    await dir.create(recursive: true);
    return _dir = dir;
  }

  String _episodeKey(String itemId) => 'episode:$itemId';

  bool _isEpisode(dynamic value) =>
      value is Map &&
      value['seriesId'] is String &&
      (value['seriesId'] as String).isNotEmpty &&
      value['itemId'] is String &&
      (value['itemId'] as String).isNotEmpty &&
      value['keyHex'] is String &&
      value['filePath'] is String &&
      (value['filePath'] as String).isNotEmpty;

  @override
  Future<void> ensureCatalogue(CachedDrama drama) => _serialize((box) async {
    if (drama.id.isEmpty || drama.episodes.isEmpty) return;
    final record = drama.toMap()
      ..['cachedAt'] = DateTime.now().millisecondsSinceEpoch;
    await box.put('series:${drama.id}', record);
    changes.value++;
  });

  @override
  Future<void> saveEpisode(CachedEpisode episode) => _serialize((box) async {
    if (episode.seriesId.isEmpty || episode.itemId.isEmpty) return;
    await box.put(_episodeKey(episode.itemId), episode.toMap());
    changes.value++;
  });

  @override
  Future<bool> isDownloaded(String itemId) => _serialize((box) async {
    return _isEpisode(box.get(_episodeKey(itemId)));
  });

  @override
  Future<CachedEpisode?> episode(String itemId) => _serialize((box) async {
    final raw = box.get(_episodeKey(itemId));
    return _isEpisode(raw) ? CachedEpisode.fromMap(raw) : null;
  });

  @override
  Future<bool> hasCatalogue(String seriesId) => _serialize((box) async {
    return box.get('series:$seriesId') != null;
  });

  @override
  Future<List<CachedDramaSummary>> dramas() => _serialize((box) async {
    final bySeries = <String, List<CachedEpisode>>{};
    for (final value in box.values) {
      if (!_isEpisode(value)) continue;
      final episode = CachedEpisode.fromMap(value);
      if (episode == null) continue;
      (bySeries[episode.seriesId] ??= []).add(episode);
    }
    final summaries = <CachedDramaSummary>[];
    for (final entry in bySeries.entries) {
      final drama =
          CachedDrama.fromMap(box.get('series:${entry.key}')) ??
          CachedDrama(
            id: entry.key,
            title: entry.key,
            cover: '',
            episodes: [
              for (final episode in entry.value)
                Chapter(
                  itemId: episode.itemId,
                  title: episode.title,
                  volumeName: '',
                ),
            ],
          );
      entry.value.sort((a, b) => a.index.compareTo(b.index));
      summaries.add(CachedDramaSummary(drama, entry.value));
    }
    summaries.sort((a, b) {
      final at = a.episodes
          .map((episode) => episode.cachedAt)
          .fold(0, (max, value) => value > max ? value : max);
      final bt = b.episodes
          .map((episode) => episode.cachedAt)
          .fold(0, (max, value) => value > max ? value : max);
      return bt.compareTo(at);
    });
    return summaries;
  });

  @override
  Future<int> totalBytes() => _serialize((box) async {
    var bytes = 0;
    for (final value in box.values) {
      if (!_isEpisode(value)) continue;
      final size = value['bytes'];
      if (size is num && size.isFinite && size > 0) bytes += size.toInt();
    }
    return bytes;
  });

  @override
  Future<void> removeEpisode(String itemId) => _serialize((box) async {
    final raw = box.get(_episodeKey(itemId));
    if (_isEpisode(raw)) {
      // 记录指向的文件随记录删除；路径被篡改时宁可留着文件也不删错。
      final filePath = raw['filePath'] as String;
      try {
        await File(filePath).delete();
      } on FileSystemException catch (_) {
        // 文件已不存在是删除的常态结果。
      } on ArgumentError catch (_) {
        // 非法路径：记录照样删，文件留给系统清理。
      }
    }
    await box.delete(_episodeKey(itemId));
    changes.value++;
  });

  @override
  Future<void> removeDrama(String seriesId) => _serialize((box) async {
    if (seriesId.isEmpty) return;
    final doomed = <String>[
      'series:$seriesId',
      for (final value in box.values)
        if (_isEpisode(value) && value['seriesId'] == seriesId)
          _episodeKey(value['itemId'] as String),
    ];
    for (final value in box.values) {
      if (!_isEpisode(value) || value['seriesId'] != seriesId) continue;
      try {
        await File(value['filePath'] as String).delete();
      } on FileSystemException catch (_) {
      } on ArgumentError catch (_) {}
    }
    await box.deleteAll(doomed);
    changes.value++;
  });
}
