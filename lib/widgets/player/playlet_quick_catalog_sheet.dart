import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/api_client.dart';
import '../../services/player_history.dart';
import '../../services/library_store.dart';
import '../../services/user_facing_error.dart';

/// 快速选集半屏抽屉：在 Feed 流中无需跳页，快速预览剧集目录并就地选择集数或全屏观看。
class PlayletQuickCatalogSheet extends StatefulWidget {
  final MediaItem item;
  final Future<List<List<Chapter>>> Function(String id, String tab)?
  directoryLoader;
  final ReaderStore? historyStore;
  final void Function(int episodeIndex, List<Chapter> allEpisodes)
  onEpisodeSelected;
  final VoidCallback onFullscreen;

  const PlayletQuickCatalogSheet({
    super.key,
    required this.item,
    this.directoryLoader,
    this.historyStore,
    required this.onEpisodeSelected,
    required this.onFullscreen,
  });

  static Future<void> show(
    BuildContext context, {
    required MediaItem item,
    Future<List<List<Chapter>>> Function(String id, String tab)?
    directoryLoader,
    ReaderStore? historyStore,
    required void Function(int episodeIndex, List<Chapter> allEpisodes)
    onEpisodeSelected,
    required VoidCallback onFullscreen,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PlayletQuickCatalogSheet(
        item: item,
        directoryLoader: directoryLoader,
        historyStore: historyStore,
        onEpisodeSelected: onEpisodeSelected,
        onFullscreen: onFullscreen,
      ),
    );
  }

  @override
  State<PlayletQuickCatalogSheet> createState() =>
      _PlayletQuickCatalogSheetState();
}

class _PlayletQuickCatalogSheetState extends State<PlayletQuickCatalogSheet> {
  bool _loading = true;
  String? _error;
  List<Chapter> _episodes = const [];
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadDirectory();
  }

  Future<void> _loadDirectory() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final item = widget.item;
    final contentId = item.seriesId ?? item.id;
    final tab = item.kind == 'manju' ? '漫剧' : '短剧';

    try {
      final loader = widget.directoryLoader;
      final volumes = loader != null
          ? await loader(contentId, tab)
          : await ApiClient.instance.directoryChapters(contentId, tab: tab);

      final eps = volumes.expand((volume) => volume).toList(growable: false);
      if (eps.isEmpty && item.episodeId != null) {
        eps.add(
          Chapter(
            itemId: item.episodeId!,
            title: item.title,
            volumeName: '剧集',
          ),
        );
      }

      int resumeIndex = 0;
      try {
        final saved = await PlayerHistory(
          widget.historyStore ?? LibraryStore.instance,
        ).load(contentId);
        resumeIndex = (resumeEpisodeIndex(saved, eps) ?? 0).clamp(
          0,
          eps.isEmpty ? 0 : eps.length - 1,
        );
      } catch (_) {
        resumeIndex = 0;
      }

      if (!mounted) return;
      setState(() {
        _loading = false;
        _episodes = eps;
        _currentIndex = resumeIndex;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * 0.65;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E22),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 20,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top drag handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header row
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            if (_episodes.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x26FFFFFF),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '共${_episodes.length}集',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (_episodes.isNotEmpty &&
                            _currentIndex >= 0 &&
                            _currentIndex < _episodes.length)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              '上次看到：第${_currentIndex + 1}集',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFFA6725),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Fullscreen button
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.onFullscreen();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x1AFFFFFF),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0x33FFFFFF),
                          width: 0.5,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(
                            LucideIcons.maximize_2,
                            size: 13,
                            color: Colors.white,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '全屏播放',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Close button
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0x1AFFFFFF),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.x,
                        size: 16,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const Divider(color: Color(0x1FFFFFFF), height: 1),

            // Content body
            Flexible(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFFFA6725),
                ),
              ),
              SizedBox(height: 14),
              Text(
                '剧集加载中...',
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return SizedBox(
        height: 180,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                LucideIcons.circle_alert,
                size: 32,
                color: Colors.white38,
              ),
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 14),
              GestureDetector(
                onTap: _loadDirectory,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x26FFFFFF),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    '重试',
                    style: TextStyle(fontSize: 13, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_episodes.isEmpty) {
      return const SizedBox(
        height: 160,
        child: Center(
          child: Text(
            '暂无剧集数据',
            style: TextStyle(fontSize: 14, color: Colors.white54),
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.3,
      ),
      itemCount: _episodes.length,
      itemBuilder: (context, index) {
        final isCurrent = index == _currentIndex;
        final episodeNum = index + 1;

        return GestureDetector(
          onTap: () {
            Navigator.of(context).pop();
            widget.onEpisodeSelected(index, _episodes);
          },
          behavior: HitTestBehavior.opaque,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isCurrent
                  ? const Color(0x33FA6725)
                  : const Color(0x14FFFFFF),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isCurrent
                    ? const Color(0xFFFA6725)
                    : const Color(0x14FFFFFF),
                width: 1,
              ),
            ),
            child: Text(
              '$episodeNum',
              style: TextStyle(
                fontSize: 14,
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                color: isCurrent ? const Color(0xFFFA6725) : Colors.white,
              ),
            ),
          ),
        );
      },
    );
  }
}
