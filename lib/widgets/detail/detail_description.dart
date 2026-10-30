import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import '../home/home_shelf.dart';

/// `简介` block: the section heading, the clamped summary and an inline
/// expand/collapse control.
///
/// The heading is a plain `简介` on every kind: the old `书籍简介` read as
/// nonsense on audio and manga.
class DetailDescription extends StatefulWidget {
  final String text;
  final bool desktop;
  final String title;

  const DetailDescription({
    super.key,
    required this.text,
    this.desktop = false,
    this.title = '简介',
  });

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
    final style = TextStyle(
      color: palette.ink,
      fontSize: widget.desktop ? 15 : 13.5,
      height: widget.desktop ? 1.65 : 1.8,
    );
    final defaultTextStyle = DefaultTextStyle.of(context);
    final effectiveStyle = MediaQuery.boldTextOf(context)
        ? defaultTextStyle.style
              .merge(style)
              .merge(const TextStyle(fontWeight: FontWeight.bold))
        : defaultTextStyle.style.merge(style);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeSectionHeader(title: widget.title),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: widget.text.isEmpty
              ? Text('暂无简介', style: style.copyWith(color: palette.muted))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final measure = TextPainter(
                      text: TextSpan(text: widget.text, style: effectiveStyle),
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
                              onPressed: () =>
                                  setState(() => _expanded = !_expanded),
                              style: TextButton.styleFrom(
                                foregroundColor: palette.accentText,
                                minimumSize: const Size(48, 40),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _expanded ? '收起' : '展开',
                                    style: const TextStyle(fontSize: 12.5),
                                  ),
                                  if (!palette.eink) ...[
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
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}
