import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// Book identity and reading actions. There is no rating or shelf row.
class ReaderClassicMoreSheet extends StatelessWidget {
  const ReaderClassicMoreSheet({
    super.key,
    required this.title,
    required this.author,
    required this.cover,
    required this.preset,
    required this.canBookmark,
    required this.canSearch,
    this.canDetails = true,
    this.onDetails,
    this.onAuthor,
    this.onBookmarks,
  });

  final String title;
  final String author;
  final String cover;
  final ReaderThemePreset preset;
  final bool canBookmark;
  final bool canSearch;

  /// Online details are unavailable for imported books. Metadata stays visible.
  final bool canDetails;

  /// Defaults to returning `details` from the sheet.
  final VoidCallback? onDetails;

  /// A missing callback leaves the author non-interactive, without a chevron.
  final VoidCallback? onAuthor;

  /// Defaults to returning `bookmarks` from the sheet.
  final VoidCallback? onBookmarks;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Padding(
      key: const ValueKey('reader-classic-more-sheet'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: preset.mutedTextColor.withValues(alpha: .2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Semantics(
                  label: canDetails ? '书籍详情' : '书籍封面',
                  button: canDetails,
                  child: InkWell(
                    key: const ValueKey('classic-reader-cover'),
                    onTap: canDetails ? () => _showDetails(context) : null,
                    borderRadius: BorderRadius.circular(4),
                    child: ExcludeSemantics(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: SizedBox(
                          width: 48,
                          height: 68,
                          child: cover.isEmpty
                              ? _coverPlaceholder()
                              : Image.network(
                                  cover,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      _coverPlaceholder(),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        key: const ValueKey('classic-reader-title'),
                        onTap: canDetails ? () => _showDetails(context) : null,
                        borderRadius: BorderRadius.circular(4),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: preset.textColor,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (author.trim().isNotEmpty)
                        Semantics(
                          button: onAuthor != null,
                          child: InkWell(
                            key: const ValueKey('classic-reader-author'),
                            onTap: onAuthor,
                            borderRadius: BorderRadius.circular(4),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 48),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        author,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: preset.mutedTextColor,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    if (onAuthor != null) ...[
                                      const SizedBox(width: 4),
                                      Icon(
                                        LucideIcons.chevron_right,
                                        size: 14,
                                        color: preset.mutedTextColor,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              // Keep the circular buttons; wrap before scaled labels get tight.
              final labelWidth = MediaQuery.textScalerOf(context).scale(13) * 4;
              final minWidth = labelWidth + 16 < 72 ? 72.0 : labelWidth + 16;
              final columns = (constraints.maxWidth / minWidth).floor().clamp(
                1,
                4,
              );
              final width = constraints.maxWidth / columns;
              return Wrap(
                runSpacing: 8,
                children: [
                  if (canDetails)
                    SizedBox(
                      width: width,
                      child: _action(
                        'classic-reader-details',
                        LucideIcons.book_open,
                        '书籍详情',
                        () => _showDetails(context),
                      ),
                    ),
                  SizedBox(
                    width: width,
                    child: _action(
                      'classic-reader-add-bookmark',
                      LucideIcons.bookmark_plus,
                      '添加书签',
                      canBookmark
                          ? () => Navigator.pop(context, 'bookmark')
                          : null,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _action(
                      'classic-reader-bookmarks',
                      LucideIcons.bookmark,
                      '书签管理',
                      onBookmarks ?? () => Navigator.pop(context, 'bookmarks'),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _action(
                      'classic-reader-full-search',
                      LucideIcons.search,
                      '全文搜索',
                      canSearch ? () => Navigator.pop(context, 'search') : null,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    ),
  );

  void _showDetails(BuildContext context) {
    if (!canDetails) return;
    if (onDetails case final callback?) {
      callback();
    } else {
      Navigator.pop(context, 'details');
    }
  }

  Widget _coverPlaceholder() => ColoredBox(
    color: preset.mutedTextColor.withValues(alpha: .08),
    child: Icon(LucideIcons.book_open, color: preset.mutedTextColor),
  );

  Widget _action(
    String key,
    IconData icon,
    String label,
    VoidCallback? onPressed,
  ) => TextButton(
    key: ValueKey(key),
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: preset.textColor,
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: preset.mutedTextColor.withValues(alpha: .05),
          ),
          child: Icon(icon, size: 28),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13),
        ),
      ],
    ),
  );
}
