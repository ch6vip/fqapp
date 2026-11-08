import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_ui/app_ui_scope.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';
import '../wenku/wenku_ui.dart';
import 'detail_states.dart';

/// `简介` block: the section heading, the clamped summary and an inline
/// expand/collapse control.
///
/// The heading is a plain `简介` on every kind: the old `书籍简介` read as
/// nonsense on audio and manga. 档案 keeps the `01 / SYNOPSIS` archive heading;
/// 经典 uses the old 15sp text header, so the classic phone detail page and the
/// Windows desktop column follow the selected style.
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
    final classic = AppUiScope.isClassic(context);
    final palette = HomePalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bodyColor = classic ? palette.ink : scheme.onSurface;
    final style = TextStyle(
      color: bodyColor,
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
        if (classic)
          DetailSectionHeader(title: widget.title)
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: homeGutter),
            child: sectionHeader(context, widget.title, ''),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: widget.text.isEmpty
              ? Text(
                  '暂无简介',
                  style: style.copyWith(
                    color: classic ? palette.muted : scheme.onSurfaceVariant,
                  ),
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
                                      color: classic
                                          ? palette.muted
                                          : scheme.onSurfaceVariant,
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
