import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// The official g6h entry; its optional guide only opens after a real cover loads.
class ReaderVideoButton extends StatefulWidget {
  const ReaderVideoButton({
    super.key,
    required this.menuVisibility,
    required this.preset,
    required this.cover,
    required this.loading,
    required this.onTap,
  });

  final ReaderThemePreset preset;
  final ValueListenable<bool> menuVisibility;
  final String cover;
  final bool loading;
  final VoidCallback? onTap;

  @override
  State<ReaderVideoButton> createState() => _ReaderVideoButtonState();
}

class _ReaderVideoButtonState extends State<ReaderVideoButton>
    with WidgetsBindingObserver {
  static const _guideKey = 'reader_video_guide_seen';
  bool _guideAllowed = false;
  bool _coverLoaded = false;
  bool _coverFramePending = false;
  bool _expanded = false;
  bool _routeCurrent = false;
  bool _reducedMotion = true;
  bool _foreground =
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  Timer? _guideTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.menuVisibility.addListener(_visibilityChanged);
    unawaited(_loadGuide());
  }

  Future<void> _loadGuide() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _guideAllowed = !(prefs.getBool(_guideKey) ?? false);
          _syncGuide();
        });
      }
    } catch (_) {
      // Guidance is optional; the entry works without persistence.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _reducedMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    _syncGuide();
  }

  @override
  void didUpdateWidget(ReaderVideoButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.menuVisibility, widget.menuVisibility)) {
      oldWidget.menuVisibility.removeListener(_visibilityChanged);
      widget.menuVisibility.addListener(_visibilityChanged);
    }
    if (oldWidget.cover != widget.cover) {
      _coverLoaded = false;
    }
    _syncGuide();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      _syncGuide();
    });
  }

  void _visibilityChanged() => setState(_syncGuide);

  bool get _canShowGuide =>
      widget.menuVisibility.value &&
      _routeCurrent &&
      _foreground &&
      !widget.preset.isEink &&
      !_reducedMotion &&
      !widget.loading &&
      widget.onTap != null &&
      _coverLoaded;

  void _syncGuide() {
    if (!_canShowGuide) {
      _guideTimer?.cancel();
      _guideTimer = null;
      _expanded = false;
    } else if (_guideAllowed && !_expanded && _guideTimer == null) {
      _guideTimer = Timer(const Duration(milliseconds: 300), _expandGuide);
    }
  }

  void _coverReady() {
    if (_coverLoaded || _coverFramePending) return;
    _coverFramePending = true;
    final cover = widget.cover;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _coverFramePending = false;
      if (!mounted || widget.cover != cover) return;
      _coverLoaded = true;
      _syncGuide();
    });
  }

  void _expandGuide() {
    _guideTimer = null;
    if (!mounted || !_canShowGuide || !_guideAllowed) return;
    setState(() => _expanded = true);
  }

  void _onGuideExpanded() {
    if (!_canShowGuide || !_expanded || !_guideAllowed) return;
    // A timer can fire before a rendered frame; count the completed animation.
    _guideAllowed = false;
    unawaited(_rememberGuide());
    _guideTimer = Timer(const Duration(seconds: 5), () {
      _guideTimer = null;
      if (mounted) setState(() => _expanded = false);
    });
  }

  Future<void> _rememberGuide() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_guideKey, true);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.menuVisibility.removeListener(_visibilityChanged);
    _guideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final expanded = _expanded && _canShowGuide;
    final asset = switch (preset) {
      ReaderThemePreset.eyeCare => 'video_eye_care',
      ReaderThemePreset.parchment => 'video_parchment',
      ReaderThemePreset.dark => 'video_dark',
      _ => 'video_light',
    };
    final background = switch (preset) {
      ReaderThemePreset.eyeCare => const Color(0xFF555D50),
      ReaderThemePreset.parchment => const Color(0xFF705C3B),
      ReaderThemePreset.dark => const Color(0xFF333333),
      _ => const Color(0xFF6B6B6B),
    };
    return Semantics(
      button: true,
      enabled: !widget.loading && widget.onTap != null,
      label: widget.loading ? '正在打开改编剧' : '播放本书改编剧',
      child: Material(
        color: preset.isEink ? Colors.white : background,
        shape: StadiumBorder(
          side: preset.isEink ? const BorderSide() : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.loading ? null : widget.onTap,
          child: AnimatedContainer(
            onEnd: _onGuideExpanded,
            duration:
                _reducedMotion || preset.isEink || !widget.menuVisibility.value
                ? Duration.zero
                : const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            width: expanded ? 232 : 56,
            height: 56,
            child: _content(preset, asset, expanded),
          ),
        ),
      ),
    );
  }

  Widget _content(ReaderThemePreset preset, String asset, bool expanded) =>
      Stack(
        clipBehavior: Clip.hardEdge,
        alignment: Alignment.centerRight,
        children: [
          if (expanded)
            const Positioned(
              left: 19,
              right: 63,
              child: Text(
                '播放本书改编剧',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          if (widget.cover.isNotEmpty) _cover(expanded),
          if (expanded)
            const Positioned(
              right: 19,
              child: Icon(Icons.play_arrow, color: Colors.white, size: 18),
            ),
          if (!expanded)
            ExcludeSemantics(
              child: preset.isEink
                  ? const SizedBox.square(
                      dimension: 56,
                      child: Center(
                        child: Text('看', style: TextStyle(fontSize: 32)),
                      ),
                    )
                  : Image.asset(
                      'assets/images/reader/$asset.webp',
                      width: 56,
                      height: 56,
                    ),
            ),
          if (widget.loading)
            Positioned(
              right: 18,
              child: SizedBox.square(
                dimension: 20,
                child: _reducedMotion || preset.isEink
                    ? const Icon(Icons.hourglass_empty, size: 20)
                    : const CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      );

  Widget _cover(bool expanded) => Positioned(
    right: 7,
    width: 42,
    height: 42,
    child: ExcludeSemantics(
      child: Opacity(
        opacity: expanded ? 1 : 0,
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: widget.cover,
            fit: BoxFit.cover,
            imageBuilder: (context, provider) {
              _coverReady();
              return Image(image: provider, fit: BoxFit.cover);
            },
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}
