import 'package:flutter/material.dart';

import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'detail_states.dart';

/// `简介` block: the section heading, the clamped summary and an inline
/// expand/collapse control.
///
/// The heading is a plain `简介` on every kind: the old `书籍简介` read as
/// nonsense on audio and manga. The mockup's `展开` is plain 12dp muted text
/// under the paragraph, not an accent button.
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
    final style = TextStyle(
      color: palette.ink,
      fontSize: widget.desktop ? 15 : 13,
      height: widget.desktop ? 1.65 : 1.5,
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
        DetailSectionHeader(title: widget.title),
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
                          duration: MediaQuery.disableAnimationsOf(context)
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
                          HomePressable(
                            key: const Key('detail_description_toggle'),
                            semanticLabel: _expanded ? '收起简介' : '展开简介',
                            onTap: () => setState(() => _expanded = !_expanded),
                            borderRadius: BorderRadius.circular(4),
                            child: Text(
                              _expanded ? '收起' : '展开',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 12,
                                height: 1.5,
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
