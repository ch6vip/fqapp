import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';

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
    final style = TextStyle(color: palette.muted, fontSize: 14, height: 1.85);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: palette.line.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 17,
                margin: const EdgeInsets.only(right: 9),
                decoration: BoxDecoration(
                  color: HomePalette.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Text(
                  '故事简介',
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(LucideIcons.quote, size: 22, color: palette.line),
            ],
          ),
          const SizedBox(height: 12),
          if (widget.text.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('暂无简介', style: style),
            )
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
                          : const Duration(milliseconds: 280),
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
                            minimumSize: const Size(48, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _expanded ? '收起简介' : '展开简介',
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(width: 4),
                              AnimatedRotation(
                                turns: _expanded ? 0.5 : 0,
                                duration: reducedMotion
                                    ? Duration.zero
                                    : const Duration(milliseconds: 240),
                                child: const Icon(
                                  LucideIcons.chevron_down,
                                  size: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      const SizedBox(height: 10),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}
