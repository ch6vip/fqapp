import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// The official f7s glyph; playback controls belong to the global capsule.
class ReaderListenButton extends StatelessWidget {
  const ReaderListenButton({
    super.key,
    required this.preset,
    required this.loading,
    required this.unavailable,
    required this.onTap,
  });

  final ReaderThemePreset preset;
  final bool loading;
  final bool unavailable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final asset = switch (preset) {
      ReaderThemePreset.eyeCare => 'listen_eye_care',
      ReaderThemePreset.parchment => 'listen_parchment',
      ReaderThemePreset.dark => 'listen_dark',
      _ => 'listen_light',
    };
    final reducedMotion =
        preset.isEink ||
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    return Semantics(
      button: true,
      enabled: !loading && onTap != null,
      label: loading
          ? '正在开始听书'
          : unavailable
          ? '听书，暂无可用资源'
          : '听当前书',
      child: Material(
        color: preset.isEink ? Colors.white : Colors.transparent,
        shape: CircleBorder(
          side: preset.isEink ? const BorderSide() : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: loading ? null : onTap,
          child: SizedBox.square(
            dimension: kReaderActionSize,
            child: ExcludeSemantics(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (preset.isEink)
                    const Text(
                      '听',
                      // 42 圆里字框四角离圆心 = 字号×√2/2，要 ≤ 半径 21，
                      // 字号上限约 29。28 贴住上限留一点余量；32 会出圆被裁。
                      style: TextStyle(color: Colors.black, fontSize: 28),
                    )
                  else
                    Ink.image(
                      image: AssetImage('assets/images/reader/$asset.webp'),
                      width: kReaderActionSize,
                      height: kReaderActionSize,
                      fit: BoxFit.contain,
                    ),
                  if (loading)
                    SizedBox.square(
                      dimension: 18,
                      child: reducedMotion
                          ? Icon(Icons.hourglass_empty, color: preset.textColor)
                          : const CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
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
