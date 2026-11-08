part of '../author_page.dart';

/// Classic author home (经典主题).
///
/// Restored from fqapp-backup@f329399 `pages/author_page.dart`: a plain Material
/// AppBar with `作者` and the shared back button, the profile header (avatar,
/// name + level chip, follower/work facts, bio) and the author's works as the
/// home `HomeMediaCard` grid.
///
/// Display only. It keeps the current request state (`_loading` / `_error` /
/// `_profile`), the generation guard and reload in [_AuthorPageState._load], the
/// `author_retry` entry, the level chip and `openBookDetail` for every work;
/// nothing here resolves a book by itself.
extension _AuthorPageClassic on _AuthorPageState {
  Widget _buildClassicPage(BuildContext context, HomePalette palette) {
    return Scaffold(
      key: const Key('author-classic-page'),
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
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
            color: palette.eink ? palette.ink : HomePalette.accent,
            backgroundColor: palette.surface,
            child: _classicBody(palette),
          ),
        ),
      ),
    );
  }

  Widget _classicBody(HomePalette palette) {
    if (_loading) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Center(
            child: CircularProgressIndicator(
              color: palette.eink ? palette.ink : HomePalette.accent,
            ),
          ),
        ],
      );
    }
    final error = _error;
    if (error != null) {
      return ListView(
        children: [
          const SizedBox(height: 60),
          Icon(LucideIcons.user_x, size: 32, color: palette.muted),
          const SizedBox(height: 14),
          Text(
            error,
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
        final works = _profile.works;
        return CustomScrollView(
          key: const Key('author_scroll'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: KeyedSubtree(
                key: contentAnchorKey('header'),
                child: _classicHeader(palette),
              ),
            ),
            if (works.isEmpty)
              SliverToBoxAdapter(
                child: HomeStateView(
                  key: const Key('author_empty'),
                  icon: LucideIcons.inbox,
                  title: '暂无可展示的作品',
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: KeyedSubtree(
                  key: contentAnchorKey('works'),
                  child: HomeSectionHeader(
                    title: '全部作品',
                    action: Text(
                      '${works.length}',
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
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
                    final work = works[index];
                    return KeyedSubtree(
                      key: contentAnchorKey('works/work:${work.id}'),
                      child: HomeMediaCard(
                        key: ValueKey('author_work_${work.id}'),
                        item: _asItem(work),
                        coverWidth: cardWidth,
                        showLength: true,
                        onTap: () => _openWork(work),
                      ),
                    );
                  }, childCount: works.length),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _classicHeader(HomePalette palette) {
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
                            _displayName,
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
}
