import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';

/// `书籍简介` block: a plain heading, the clamped summary and an inline
/// expand/collapse control, matching the official detail page.
class DetailDescription extends StatefulWidget {
  final String text;

  const DetailDescription({super.key, required this.text});

  @override
  State<DetailDescription> createState() => _DetailDescriptionState();
}

class _DetailDescriptionState extends State<DetailDescription> {
  bool _expanded = false;

  @override
  void didUpdateWidget(DetailDescription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final style = TextStyle(color: palette.ink, fontSize: 13.5, height: 1.85);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '书籍简介',
          style: TextStyle(
            color: palette.ink,
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 12),
        if (widget.text.isEmpty)
          Text('暂无简介', style: style.copyWith(color: palette.muted))
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final measure = TextPainter(
                text: TextSpan(text: widget.text, style: style),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                maxLines: 3,
              )..layout(maxWidth: constraints.maxWidth);
              final canExpand = measure.didExceedMaxLines;
              measure.dispose();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSize(
                    duration: reducedMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: Text(
                      widget.text,
                      key: const Key('detail_description_text'),
                      maxLines: _expanded ? null : 3,
                      overflow: _expanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                  if (canExpand)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const Key('detail_description_toggle'),
                        onPressed: () => setState(() => _expanded = !_expanded),
                        style: TextButton.styleFrom(
                          foregroundColor: palette.accentText,
                          minimumSize: const Size(48, 44),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _expanded ? '收起' : '展开',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                            const SizedBox(width: 3),
                            AnimatedRotation(
                              turns: _expanded ? 0.5 : 0,
                              duration: reducedMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 220),
                              child: const Icon(
                                LucideIcons.chevron_down,
                                size: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}
