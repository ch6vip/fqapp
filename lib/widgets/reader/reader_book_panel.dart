import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_detail.dart';
import '../../models/media_item.dart';
import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// One bounded book surface; each tab retains its own scroll and filter state.
class ReaderBookPanel extends StatefulWidget {
  const ReaderBookPanel({
    super.key,
    required this.book,
    required this.preset,
    required this.loadDetail,
    required this.directory,
    required this.notes,
    required this.onDetails,
    required this.onAuthor,
    required this.onSearch,
    required this.onNight,
    required this.onSettings,
    this.onAi,
    this.aiLabel = 'AI 校对',
  });

  final MediaItem book;
  final ReaderThemePreset preset;
  final Future<BookDetail> Function() loadDetail;
  final Widget directory;
  final Widget notes;
  final VoidCallback? onDetails;
  final ValueChanged<BookAuthor>? onAuthor;
  final VoidCallback onSearch;
  final VoidCallback onNight;
  final VoidCallback onSettings;
  final VoidCallback? onAi;
  final String aiLabel;

  @override
  State<ReaderBookPanel> createState() => _ReaderBookPanelState();
}

class _ReaderBookPanelState extends State<ReaderBookPanel> {
  int _tab = 1;
  late Future<BookDetail> _detail = widget.loadDetail();

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: Material(
        key: const ValueKey('reader-book-panel'),
        color: preset.panelColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, bounds) {
              final compact = bounds.maxHeight < 420;
              return FutureBuilder<BookDetail>(
                future: _detail,
                builder: (context, snapshot) {
                  final detail = snapshot.data;
                  final author = detail?.author;
                  final canOpenAuthor =
                      widget.onAuthor != null && author?.id.isNotEmpty == true;
                  final authorName = author?.name.isNotEmpty == true
                      ? author!.name
                      : widget.book.author;
                  final title = detail?.title.isNotEmpty == true
                      ? detail!.title
                      : widget.book.title;
                  final metadataHeight =
                      MediaQuery.textScalerOf(context).scale(13) * 1.4 + 12;
                  final metadataRowHeight = metadataHeight < 32
                      ? 32.0
                      : metadataHeight;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!compact) ...[
                        Center(
                          child: Container(
                            margin: const EdgeInsets.only(top: 8),
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: preset.mutedTextColor.withValues(
                                alpha: .22,
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Row(
                            children: [
                              Semantics(
                                button: widget.onDetails != null,
                                child: InkWell(
                                  key: const ValueKey('reader-book-cover'),
                                  onTap: widget.onDetails,
                                  child: SizedBox(
                                    width: 48,
                                    height: 68,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: widget.book.cover.isEmpty
                                          ? Icon(
                                              LucideIcons.book_open,
                                              color: preset.mutedTextColor,
                                            )
                                          : Image.network(
                                              widget.book.cover,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) => Icon(
                                                LucideIcons.book_open,
                                                color: preset.mutedTextColor,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Semantics(
                                      button: widget.onDetails != null,
                                      child: InkWell(
                                        key: const ValueKey(
                                          'reader-book-title',
                                        ),
                                        onTap: widget.onDetails,
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            minHeight: 48,
                                          ),
                                          child: Align(
                                            alignment: Alignment.bottomLeft,
                                            heightFactor: 1,
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 4,
                                              ),
                                              child: Text(
                                                title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: preset.textColor,
                                                  fontSize: 17,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Semantics(
                                            button: canOpenAuthor,
                                            child: InkWell(
                                              key: const ValueKey(
                                                'reader-book-author',
                                              ),
                                              onTap: canOpenAuthor
                                                  ? () => widget.onAuthor!(
                                                      author!,
                                                    )
                                                  : null,
                                              child: ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                      minHeight: 48,
                                                    ),
                                                child: Align(
                                                  alignment: Alignment.topLeft,
                                                  heightFactor: 1,
                                                  child: SizedBox(
                                                    height: metadataRowHeight,
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Flexible(
                                                          child: Text(
                                                            authorName.isEmpty
                                                                ? '作者信息暂无'
                                                                : authorName,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              color: preset
                                                                  .mutedTextColor,
                                                              fontSize: 13,
                                                            ),
                                                          ),
                                                        ),
                                                        if (canOpenAuthor)
                                                          Icon(
                                                            LucideIcons
                                                                .chevron_right,
                                                            size: 14,
                                                            color: preset
                                                                .mutedTextColor,
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Semantics(
                                          button: true,
                                          child: Tooltip(
                                            message: '全文搜索',
                                            child: InkWell(
                                              key: const ValueKey(
                                                'reader-book-full-search',
                                              ),
                                              onTap: widget.onSearch,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                      minHeight: 48,
                                                      minWidth: 48,
                                                    ),
                                                child: Align(
                                                  alignment:
                                                      Alignment.topCenter,
                                                  heightFactor: 1,
                                                  widthFactor: 1,
                                                  child: SizedBox(
                                                    height: metadataRowHeight,
                                                    child: DecoratedBox(
                                                      decoration: BoxDecoration(
                                                        color: preset
                                                            .mutedTextColor
                                                            .withValues(
                                                              alpha: .06,
                                                            ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 10,
                                                            ),
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Icon(
                                                              LucideIcons
                                                                  .search,
                                                              size: 16,
                                                              color: preset
                                                                  .mutedTextColor,
                                                            ),
                                                            const SizedBox(
                                                              width: 6,
                                                            ),
                                                            Text(
                                                              '搜全文',
                                                              style: TextStyle(
                                                                fontSize: 13,
                                                                color: preset
                                                                    .mutedTextColor,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      Row(
                        children: [
                          for (final (index, label) in const [
                            '详情',
                            '目录',
                            '笔记',
                          ].indexed)
                            Expanded(
                              child: Semantics(
                                selected: index == _tab,
                                child: TextButton(
                                  key: ValueKey('reader-book-tab-$index'),
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(48, 48),
                                    foregroundColor: index == _tab
                                        ? preset.textColor
                                        : preset.mutedTextColor,
                                  ),
                                  onPressed: () {
                                    FocusScope.of(context).unfocus();
                                    setState(() => _tab = index);
                                  },
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: index == _tab
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (compact) ...[
                            IconButton(
                              tooltip: '全文搜索',
                              onPressed: widget.onSearch,
                              icon: const Icon(LucideIcons.search, size: 20),
                            ),
                          ],
                        ],
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: _tab,
                          children: [
                            TickerMode(
                              enabled: _tab == 0,
                              child: _details(detail, snapshot),
                            ),
                            TickerMode(
                              enabled: _tab == 1,
                              child: widget.directory,
                            ),
                            TickerMode(enabled: _tab == 2, child: widget.notes),
                          ],
                        ),
                      ),
                      if (MediaQuery.viewInsetsOf(context).bottom == 0)
                        Row(
                          children: [
                            _bottom(
                              '目录',
                              LucideIcons.book_open,
                              () => setState(() => _tab = 1),
                            ),
                            if (widget.onAi case final onAi?)
                              _bottom(
                                widget.aiLabel,
                                LucideIcons.sparkles,
                                onAi,
                                key: const ValueKey('reader-book-ai'),
                              ),
                            _bottom(
                              preset.isDark ? '日间' : '夜间',
                              preset.isDark
                                  ? LucideIcons.sun
                                  : LucideIcons.moon,
                              widget.onNight,
                            ),
                            _bottom(
                              '设置',
                              LucideIcons.settings_2,
                              widget.onSettings,
                            ),
                          ],
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _bottom(
    String label,
    IconData icon,
    VoidCallback action, {
    Key? key,
  }) => Expanded(
    child: TextButton(
      key: key,
      onPressed: action,
      style: TextButton.styleFrom(
        foregroundColor: widget.preset.textColor,
        minimumSize: const Size(48, 64),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 23),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );

  Widget _details(BookDetail? detail, AsyncSnapshot<BookDetail> snapshot) {
    final preset = widget.preset;
    final text = detail?.abstract.isNotEmpty == true
        ? detail!.abstract
        : widget.book.intro;
    final tags = detail?.tags.isNotEmpty == true
        ? detail!.tags
        : widget.book.categories;
    return ListView(
      key: const ValueKey('reader-book-details'),
      padding: const EdgeInsets.all(16),
      children: [
        if (snapshot.connectionState != ConnectionState.done)
          LinearProgressIndicator(color: preset.accentColor),
        if (snapshot.hasError)
          Row(
            children: [
              const Expanded(child: Text('书籍信息暂时无法加载')),
              TextButton(
                onPressed: () => setState(() {
                  _detail = widget.loadDetail();
                }),
                child: const Text('重试'),
              ),
            ],
          ),
        Text(
          '简介',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: preset.textColor,
          ),
        ),
        if (tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in tags)
                  Chip(
                    label: Text(tag, style: const TextStyle(fontSize: 12)),
                    backgroundColor: preset.fieldColor,
                    side: BorderSide.none,
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Text(
          text.isEmpty ? '暂无简介' : text,
          style: TextStyle(fontSize: 16, height: 1.7, color: preset.textColor),
        ),
      ],
    );
  }
}
