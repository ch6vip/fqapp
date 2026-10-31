import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/author_profile.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/poster_cache.dart';
import '../services/user_facing_error.dart';
import '../widgets/home/home_back_button.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';
import 'detail_page.dart';

/// Loads an author profile. Injectable so the page can be tested offline.
typedef AuthorLoader = Future<AuthorProfile> Function(String authorId);

/// Author home: profile header plus the author's works.
///
/// Note: the works come from `author_book_info` on the profile response, not
/// from `/authors/{id}/bookshelf` — see
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
class AuthorPage extends StatefulWidget {
  final String authorId;
  final String fallbackName;
  final AuthorLoader? loader;

  const AuthorPage({
    super.key,
    required this.authorId,
    this.fallbackName = '',
    this.loader,
  });

  @override
  State<AuthorPage> createState() => _AuthorPageState();
}

class _AuthorPageState extends State<AuthorPage> {
  AuthorProfile _profile = AuthorProfile.empty;
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final loader = widget.loader;
      final profile = loader != null
          ? await loader(widget.authorId)
          : await ApiClient.instance.authorProfile(widget.authorId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _profile = profile;
        _loading = false;
        _error = profile.isEmpty ? '作者信息不可用' : null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = userFacingError(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: const HomeBackButton(),
        // 作者名只在头部出现一次（原先 AppBar 与头部重复）。
        title: Text(
          '作者',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: RefreshIndicator(
            onRefresh: _load,
            color: HomePalette.accent,
            backgroundColor: palette.surface,
            child: _body(palette),
          ),
        ),
      ),
    );
  }

  Widget _body(HomePalette palette) {
    if (_loading) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          const Center(
            child: CircularProgressIndicator(color: HomePalette.accent),
          ),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 60),
          Icon(LucideIcons.user_x, size: 32, color: palette.muted),
          const SizedBox(height: 14),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton.icon(
              key: const Key('author_retry'),
              onPressed: _load,
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.accentText,
                side: BorderSide(color: palette.line),
                minimumSize: const Size(110, 48),
              ),
              icon: const Icon(LucideIcons.refresh_cw, size: 16),
              label: const Text('重试'),
            ),
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 网格与首页同一套：16dp 栏距、12dp 列距、HomeMediaCard。
        final width = constraints.maxWidth - homeGutter * 2;
        final cardWidth = homeShelfCardWidth(context, width);
        return CustomScrollView(
          key: const Key('author_scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header(palette)),
            if (_profile.works.isEmpty)
              SliverToBoxAdapter(
                child: HomeStateView(
                  key: const Key('author_empty'),
                  icon: LucideIcons.inbox,
                  title: '暂无可展示的作品',
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: HomeSectionHeader(
                  title: '全部作品',
                  action: Text(
                    '${_profile.works.length}',
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  homeGutter,
                  0,
                  homeGutter,
                  28,
                ),
                sliver: SliverGrid(
                  gridDelegate: homeShelfDelegate(context, width),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final work = _profile.works[index];
                    return HomeMediaCard(
                      key: ValueKey('author_work_${work.id}'),
                      item: _asItem(work),
                      coverWidth: cardWidth,
                      showLength: true,
                      onTap: () => _openWork(work),
                    );
                  }, childCount: _profile.works.length),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _header(HomePalette palette) {
    final profile = _profile;
    final facts = [
      if (profile.followerLabel.isNotEmpty) profile.followerLabel,
      if (profile.workCountLabel.isNotEmpty) profile.workCountLabel,
      if (profile.works.isNotEmpty && profile.workCount == 0)
        '${profile.works.length} 部作品',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(homeGutter, 4, homeGutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipOval(
                child: SizedBox.square(
                  dimension: 58,
                  child: profile.avatar.isEmpty
                      ? ColoredBox(
                          color: palette.soft,
                          child: Icon(
                            LucideIcons.user,
                            size: 26,
                            color: palette.muted,
                          ),
                        )
                      : CachedNetworkImage(
                          cacheManager: PosterCache.instance,
                          imageUrl: profile.avatar,
                          fit: BoxFit.cover,
                          // 58dp avatar; decode at 2×.
                          memCacheWidth: 128,
                          errorWidget: (context, url, error) => ColoredBox(
                            color: palette.soft,
                            child: Icon(
                              LucideIcons.user,
                              size: 26,
                              color: palette.muted,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            profile.name.isEmpty
                                ? widget.fallbackName
                                : profile.name,
                            key: const Key('author_name'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.ink,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        if (profile.level.isNotEmpty) ...[
                          const SizedBox(width: 7),
                          _LevelChip(text: profile.level),
                        ],
                      ],
                    ),
                    if (facts.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        facts.join(' · '),
                        style: TextStyle(color: palette.muted, fontSize: 12.5),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (profile.description.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              profile.description,
              key: const Key('author_description'),
              style: TextStyle(color: palette.ink, fontSize: 13.5, height: 1.7),
            ),
          ],
        ],
      ),
    );
  }

  /// The work is opened through the normal detail page, which resolves the
  /// whole record (the author payload only carries a summary).
  static MediaItem _asItem(AuthorWork work) => MediaItem(
    id: work.id,
    title: work.title,
    cover: work.cover,
    author: '',
    badge: work.category,
    ep: '',
    kind: 'book',
    // 卡片副标题的长度与详情页的分类都靠这两项；作者页的作品条目本身
    // 就带着 word_number / category，之前漏掉了。
    wordNumber: work.wordNumber,
    categories: work.category.isEmpty ? const [] : [work.category],
    intro: work.abstract,
  );

  void _openWork(AuthorWork work) {
    if (work.id.isEmpty) return;
    openBookDetail(context, _asItem(work));
  }
}

class _LevelChip extends StatelessWidget {
  final String text;

  const _LevelChip({required this.text});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = palette.eink ? palette.ink : palette.accentText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        // 墨水屏退化为白底 + 黑描边，浅/深色仍是品牌强调色的淡底。
        color: palette.eink ? Colors.white : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: palette.eink ? Border.all(color: palette.line) : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
    );
  }
}
