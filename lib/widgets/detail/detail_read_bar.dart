import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';

class DetailReadBar extends StatelessWidget {
  final String label;
  final String? resumeTitle;
  final IconData icon;
  final bool opening;
  final VoidCallback onRead;
  final VoidCallback onDirectory;

  const DetailReadBar({
    super.key,
    required this.label,
    required this.icon,
    required this.opening,
    required this.onRead,
    required this.onDirectory,
    this.resumeTitle,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final largeType = MediaQuery.textScalerOf(context).scale(16) > 24;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (resumeTitle != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.clock_arrow_up,
                            size: 13,
                            color: palette.muted,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              '上次读到：$resumeTitle',
                              key: const Key('detail_resume_label'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 11,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      Tooltip(
                        message: '打开目录',
                        child: HomePressable(
                          key: const Key('detail_directory_button'),
                          semanticLabel: '打开目录',
                          onTap: onDirectory,
                          child: Container(
                            constraints: BoxConstraints(
                              minWidth: largeType ? 48 : 66,
                              minHeight: 56,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: palette.soft,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  LucideIcons.list,
                                  color: palette.ink,
                                  size: 21,
                                ),
                                if (!largeType) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    '目录',
                                    style: TextStyle(
                                      color: palette.ink,
                                      fontSize: 10,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Semantics(
                          enabled: !opening,
                          child: IgnorePointer(
                            ignoring: opening,
                            child: HomePressable(
                              key: const Key('detail_read_button'),
                              onTap: onRead,
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 56,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 15,
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: opening
                                        ? [palette.muted, palette.muted]
                                        : const [
                                            HomePalette.accent,
                                            Color(0xFFE4432E),
                                          ],
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: opening
                                      ? null
                                      : [
                                          BoxShadow(
                                            color: HomePalette.accent
                                                .withValues(alpha: 0.18),
                                            blurRadius: 14,
                                            offset: const Offset(0, 5),
                                          ),
                                        ],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (!largeType) ...[
                                      if (opening)
                                        const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      else
                                        Icon(
                                          icon,
                                          color: Colors.white,
                                          size: 21,
                                        ),
                                      const SizedBox(width: 10),
                                    ],
                                    Flexible(
                                      child: Text(
                                        opening ? '正在打开' : label,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          height: 1.4,
                                        ),
                                      ),
                                    ),
                                  ],
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
          ),
        ),
      ),
    );
  }
}
