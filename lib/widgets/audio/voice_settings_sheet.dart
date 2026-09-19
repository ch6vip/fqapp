import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';

/// One selectable entry in the 声音设置 sheet.
class VoiceOption {
  const VoiceOption({
    required this.id,
    required this.title,
    this.description = '',
    this.badge = '',
    this.isMultiTone = false,
  });

  final String id;
  final String title;
  final String description;
  final String badge;
  final bool isMultiTone;
}

/// 声音设置 panel mirroring the official client: 真人讲书 rows, then a
/// two-column 智能朗读 grid.
///
/// The official panel also has an 离线朗读 grid with download affordances.
/// It was never rendered here (the download affordance is a stub telling the
/// user to download in the official client), so the unreachable offline
/// parameter chain was removed rather than half-kept; playinfo rejects
/// offline tone ids outright and the selection filter still excludes them.
class VoiceSettingsSheet extends StatelessWidget {
  final String selectedId;
  final List<VoiceOption> narrators;
  final List<VoiceOption> online;
  final ValueChanged<VoiceOption> onSelect;

  const VoiceSettingsSheet({
    super.key,
    required this.selectedId,
    this.narrators = const [],
    this.online = const [],
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.canvas,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            SizedBox(
              height: 60,
              child: Stack(
                children: [
                  Align(
                    alignment: Alignment.center,
                    child: Text(
                      '声音设置',
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      key: const Key('voice_settings_close'),
                      tooltip: '关闭',
                      onPressed: () => Navigator.maybePop(context),
                      style: IconButton.styleFrom(foregroundColor: palette.ink),
                      icon: const Icon(LucideIcons.check, size: 22),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: palette.line.withValues(alpha: 0.6)),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (narrators.isNotEmpty) ...[
                      _SectionTitle('真人讲书'),
                      const SizedBox(height: 12),
                      for (final voice in narrators) ...[
                        _NarratorRow(
                          voice: voice,
                          selected: voice.id == selectedId,
                          onTap: () => onSelect(voice),
                        ),
                        const SizedBox(height: 10),
                      ],
                      const SizedBox(height: 10),
                    ],
                    if (online.isNotEmpty) ...[
                      _SectionTitle('智能朗读'),
                      const SizedBox(height: 12),
                      _VoiceGrid(
                        voices: online,
                        selectedId: selectedId,
                        onSelect: onSelect,
                      ),
                      const SizedBox(height: 22),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Text(
      text,
      style: TextStyle(
        color: palette.ink,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _NarratorRow extends StatelessWidget {
  final VoiceOption voice;
  final bool selected;
  final VoidCallback onTap;

  const _NarratorRow({
    required this.voice,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      key: ValueKey('voice_option_${voice.id}'),
      semanticLabel: voice.title,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? HomePalette.accent.withValues(alpha: 0.10)
              : palette.soft,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? HomePalette.accent.withValues(alpha: 0.55)
                : Colors.transparent,
          ),
        ),
        alignment: Alignment.centerLeft,
        child: Text(
          voice.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? palette.accentText : palette.ink,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _VoiceGrid extends StatelessWidget {
  final List<VoiceOption> voices;
  final String selectedId;
  final ValueChanged<VoiceOption> onSelect;

  const _VoiceGrid({
    required this.voices,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var index = 0; index < voices.length; index += 2) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _VoiceCard(
                voice: voices[index],
                selected: voices[index].id == selectedId,
                onSelect: onSelect,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: index + 1 < voices.length
                  ? _VoiceCard(
                      voice: voices[index + 1],
                      selected: voices[index + 1].id == selectedId,
                      onSelect: onSelect,
                    )
                  : const SizedBox(),
            ),
          ],
        ),
      );
      if (index + 2 < voices.length) rows.add(const SizedBox(height: 12));
    }
    return Column(children: rows);
  }
}

class _VoiceCard extends StatelessWidget {
  final VoiceOption voice;
  final bool selected;
  final ValueChanged<VoiceOption> onSelect;

  const _VoiceCard({
    required this.voice,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      key: ValueKey('voice_option_${voice.id}'),
      semanticLabel: voice.title,
      onTap: () => onSelect(voice),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 64,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: selected
              ? HomePalette.accent.withValues(alpha: 0.10)
              : palette.soft,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? HomePalette.accent.withValues(alpha: 0.55)
                : Colors.transparent,
          ),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                voice.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected
                                      ? palette.accentText
                                      : palette.ink,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (voice.isMultiTone) ...[
                              const SizedBox(width: 4),
                              Icon(
                                LucideIcons.audio_lines,
                                size: 14,
                                color: selected
                                    ? palette.accentText
                                    : palette.muted,
                              ),
                            ],
                          ],
                        ),
                        if (voice.description.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            voice.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check, size: 16, color: palette.accentText),
                ],
              ),
            ),
            if (voice.badge.isNotEmpty)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: HomePalette.accent.withValues(alpha: 0.12),
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(8),
                      bottomLeft: Radius.circular(6),
                    ),
                  ),
                  child: Text(
                    voice.badge,
                    style: TextStyle(
                      color: palette.accentText,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
