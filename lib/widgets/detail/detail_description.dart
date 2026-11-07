import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../home/home_shelf.dart';
import '../wenku/wenku_ui.dart';

/// `简介` block: the archive section heading, the clamped summary and an inline
/// expand/collapse control.
///
/// The heading is a plain `简介` on every kind: the old `书籍简介` read as
/// nonsense on audio and manga. Kept for fqapp's desktop column; the phone
/// detail page uses the ported `DetailArchiveSynopsis` instead. The shared
/// archive heading carries no gutter of its own, so the desktop branch pads it
/// to line up with the body text below.
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
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      color: scheme.onSurface,
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: sectionHeader(context, widget.title, ''),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: widget.text.isEmpty
              ? Text(
                  '暂无简介',
                  style: style.copyWith(color: scheme.onSurfaceVariant),
                )
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
                              : WenkuMotion.enter,
                          curve: WenkuMotion.ease,
                          alignment: Alignment.topCenter,
                          child: AppText(
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
                          JellyTapSurface(
                            key: const Key('detail_description_toggle'),
                            onTap: () => setState(() => _expanded = !_expanded),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AppText(
                                    _expanded ? '收起' : '展开全部',
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 13,
                                      height: 1.5,
                                    ),
                                  ),
                                  const SizedBox(width: 7),
                                  AnimatedRotation(
                                    turns: _expanded ? .5 : 0,
                                    duration:
                                        MediaQuery.disableAnimationsOf(context)
                                        ? Duration.zero
                                        : WenkuMotion.enter,
                                    curve: WenkuMotion.ease,
                                    child: const ArchiveIcon(
                                      CupertinoIcons.chevron_down,
                                      size: 12,
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
        ),
      ],
    );
  }
}
