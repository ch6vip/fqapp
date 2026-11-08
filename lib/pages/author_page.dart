import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/author_profile.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/app_style_tokens.dart';
import '../services/app_theme_style.dart';
import '../services/poster_cache.dart';
import '../services/user_facing_error.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/app_ui/content_anchor.dart';
import '../widgets/detail/detail_archive.dart';
import '../widgets/home/home_back_button.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'detail_page.dart';

part 'detail/author_page_classic.dart';

/// Loads an author profile. Injectable so the page can be tested offline.
typedef AuthorLoader = Future<AuthorProfile> Function(String authorId);

/// Author home: profile header plus the author's works.
///
/// 档案 is the port of Wenku8_Flutter `lib/author_works_page.dart` (revision
/// ebcd7f1): `ArchiveFeaturePage` + `sectionHeader` + the `NovelRow` list. fqapp
/// keeps its richer profile payload (avatar, level, followers, bio) above the
/// works; the work rows replace the old home-style grid with upstream's
/// cover/title rows.
///
/// 经典 (`detail/author_page_classic.dart`) restores that old grid: a Material
/// AppBar, the same profile header and the works as `HomeMediaCard`s. Both
/// branches share `_AuthorPageState`, its loader/retry and `openBookDetail`.
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

  /// Classic keeps works in a home-card grid, archive in the upstream rows;
  /// both scroll the same list, so one controller serves both bodies.
  final _scroll = ScrollController();

  /// 经典 ⇄ 档案 swaps the whole tree: keep the visible work (or the section
  /// header) instead of relying on a recreated ScrollPosition. A work deep in
  /// the list is not built after the swap, so its data index locates it first.
  late final _anchors = ContentAnchorKeeper(
    _scroll,
    indexOf: _anchorIndexOf,
    visibleTopInset: _anchorTopInset,
  );

  /// 档案 (WenkuPage) paints the glass header over the scrolling body; 经典 puts
  /// a Material AppBar above it. The anchor is measured from that visible edge.
  double _anchorTopInset(BuildContext context, AppThemeStyle style) =>
      style == AppThemeStyle.classic ? 0 : archiveChromeInset(context);

  /// Data index of an anchored work row, or null for section anchors.
  int? _anchorIndexOf(String anchorId) {
    const prefix = 'works/work:';
    if (!anchorId.startsWith(prefix)) return null;
    final id = anchorId.substring(prefix.length);
    final index = _profile.works.indexWhere((work) => work.id == id);
    return index < 0 ? null : index;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _anchors.attach(AppUiScope.maybeOf(context)?.notifier, context);
  }

  @override
  void dispose() {
    _anchors.detach();
    _scroll.dispose();
    super.dispose();
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

  String get _displayName =>
      _profile.name.isEmpty ? widget.fallbackName : _profile.name;

  @override
  Widget build(BuildContext context) {
    final style = AppUiScope.of(context);
    _anchors.noteLayoutStyle(style);
    if (style == AppThemeStyle.classic) {
      return _buildClassicPage(context, HomePalette.of(context));
    }
    return ArchiveFeaturePage(
      title: '作者作品',
      code: 'AUTHOR / WORKS',
      child: Builder(builder: _body),
    );
  }

  /// The page body always stays inside [RefreshIndicator], like upstream's
  /// `FeedRefresh`: pulling down reloads the profile from any state, including
  /// the failure screen.
  Widget _body(BuildContext context) {
    final padding = featurePadding(context);
    return RefreshIndicator(onRefresh: _load, child: _scrollBody(padding));
  }

  Widget _scrollBody(EdgeInsets padding) {
    if (_loading) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 240,
              width: double.infinity,
              child: LoadingSkeleton(
                layout: SkeletonLayout.detail,
                label: '正在加载作者',
              ),
            ),
            SizedBox(height: 18),
            AppText('正在加载作者信息'),
          ],
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        child: ContentNotice(
          icon: CupertinoIcons.person_crop_circle,
          title: '作者信息不可用',
          message: error,
          secondaryAction: GlassTextButton(
            key: const Key('author_retry'),
            onPressed: _load,
            child: const AppText('重试'),
          ),
        ),
      );
    }
    final works = _profile.works;
    return CustomScrollView(
      key: const Key('author_scroll'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: padding.copyWith(bottom: 0),
          sliver: SliverToBoxAdapter(
            child: KeyedSubtree(
              key: contentAnchorKey('header'),
              child: _profileHeader(context),
            ),
          ),
        ),
        if (works.isEmpty)
          SliverPadding(
            padding: padding.copyWith(top: 20),
            sliver: SliverToBoxAdapter(
              child: ContentNotice(
                key: const Key('author_empty'),
                icon: CupertinoIcons.book,
                title: '暂无可展示的作品',
              ),
            ),
          )
        else ...[
          SliverPadding(
            padding: padding.copyWith(top: 28, bottom: 10),
            sliver: SliverToBoxAdapter(
              child: KeyedSubtree(
                key: contentAnchorKey('works'),
                child: ArchiveSection(
                  title: '全部作品',
                  code: '02 / ARCHIVE INDEX',
                  subtitle: '${works.length} 部作品',
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: padding.copyWith(top: 0),
            sliver: SliverList.builder(
              itemCount: works.length,
              itemBuilder: (context, index) => KeyedSubtree(
                key: contentAnchorKey('works/work:${works[index].id}'),
                child: _workRow(context, works[index]),
              ),
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 32),
        ),
      ],
    );
  }

  Widget _profileHeader(BuildContext context) {
    final profile = _profile;
    final scheme = Theme.of(context).colorScheme;
    final facts = [
      if (profile.followerLabel.isNotEmpty) profile.followerLabel,
      if (profile.workCountLabel.isNotEmpty) profile.workCountLabel,
      if (profile.works.isNotEmpty && profile.workCount == 0)
        '${profile.works.length} 部作品',
    ];
    return Column(
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
                        color: scheme.surfaceContainerHighest,
                        child: ArchiveIcon(
                          CupertinoIcons.person,
                          size: 26,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    : CachedNetworkImage(
                        cacheManager: PosterCache.instance,
                        imageUrl: profile.avatar,
                        fit: BoxFit.cover,
                        memCacheWidth: 128,
                        errorWidget: (context, _, _) => ColoredBox(
                          color: scheme.surfaceContainerHighest,
                          child: ArchiveIcon(
                            CupertinoIcons.person,
                            size: 26,
                            color: scheme.onSurfaceVariant,
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
                        child: AppText(
                          _displayName,
                          key: const Key('author_name'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.3,
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
                    AppText(
                      facts.join(' · '),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (profile.description.isNotEmpty) ...[
          const SizedBox(height: 18),
          AppText(
            profile.description,
            key: const Key('author_description'),
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 13.5,
              height: 1.7,
            ),
          ),
        ],
      ],
    );
  }

  /// Upstream `NovelRow`: 56×76 cover, `ArchiveCode` + title + author, chevron.
  /// The author line is omitted because this page already belongs to that
  /// author; the meta line carries fqapp's category/status/word count.
  Widget _workRow(BuildContext context, AuthorWork work) {
    final scheme = Theme.of(context).colorScheme;
    final item = _asItem(work);
    final meta = work.metaLabel;
    return JellyTapSurface(
      key: ValueKey('author_work_${work.id}'),
      onTap: () => _openWork(work),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).dividerColor,
              width: .7,
            ),
          ),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(
                AppStyleTokens.of(context).coverRadius,
              ),
              child: SizedBox(
                width: 56,
                height: 76,
                child: work.cover.isEmpty
                    ? ColoredBox(color: scheme.surfaceContainerHighest)
                    : StoryCover(item: item, cacheWidth: 168),
              ),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (AppStyleTokens.of(context).showDecorativeCodes) ...[
                    ArchiveCode(detailArchiveFileCode(work.id)),
                    const SizedBox(height: 4),
                  ],
                  AppText(
                    work.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    AppText(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            const ArchiveIcon(CupertinoIcons.chevron_right, size: 15),
          ],
        ),
      ),
    );
  }

  /// The work is opened through the normal detail page, which resolves the
  /// whole record (the author payload only carries a summary).
  MediaItem _asItem(AuthorWork work) => MediaItem(
    id: work.id,
    title: work.title,
    cover: work.cover,
    author: _displayName,
    badge: work.category,
    ep: '',
    kind: 'book',
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
