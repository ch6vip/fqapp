import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_widgets.dart';

/// About page styled after PiliPlus: centered logo/name header, a short
/// intro paragraph, then grouped card rows (version, updates, licenses,
/// source code, feedback, ...).
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  /// Display version, kept in lockstep with pubspec.yaml's
  /// `version`. Without a package_info dependency the value is
  /// static, so test/about_version_test.dart parses the pubspec and fails the
  /// build check when the two drift apart after a version bump.
  static const versionText = '1.0.133 (138)';

  /// Bundled WeChat reward code (赞赏码), shown large in a dialog from the
  /// support card. Copied from .github/wechat.png, the same image the repo's
  /// FUNDING.yml points at.
  static const _wechatRewardAsset = 'assets/images/wechat_reward.png';

  /// Pixel width of the bundled logo (assets/images/app_logo.webp). The logo
  /// is displayed at 80dp, so it only needs re-decoding above 4× DPI; clamping
  /// to the asset's real width keeps a high-DPI device from asking the decoder
  /// to upscale a surface the asset does not have. Keep it in sync with
  /// LOGO_SIZE in scripts/generate_app_icons.py.
  static const _logoPixelWidth = 384;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = HomePalette.of(context);

    return SettingsScaffold(
      title: '关于',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          const _AboutLogo(),
          const SizedBox(height: 12),
          const _AboutHeading(),
          const SizedBox(height: 16),
          Text(
            '什锦铺把小说、短剧、漫剧、漫画和听书聚到一起。'
            '所有签名与解密都在你的手机本地完成，不依赖第三方服务。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.muted,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 12),
          const _AboutInfoCard(),
          const SizedBox(height: 12),
          const _SupportCard(),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '仅限个人学习研究使用\n请遵守相关法律法规',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: palette.muted, height: 1.5),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 版本行点按：把版本号写进剪贴板，并用 SnackBar 明示已复制。
  static void _copyVersion(BuildContext context) {
    unawaited(Clipboard.setData(const ClipboardData(text: versionText)));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制版本号')));
  }

  /// 微信赞赏码弹窗：大图 + 一句扫码提示，点遮罩或「关闭」退出。
  static Future<void> _showWechatReward(BuildContext context) {
    final palette = HomePalette.of(context);
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  _wechatRewardAsset,
                  width: 240,
                  height: 240,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '微信扫一扫，赞赏作者',
                style: TextStyle(fontSize: 14, color: palette.muted),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 头部 logo：全幅图片，圆角与投影跟随图版的 15% 板式圆角。
class _AboutLogo extends StatelessWidget {
  const _AboutLogo();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      // The bundled logo is full-bleed; 12 of 80 keeps the plate's 15%
      // corner radius so the image and the shadow outline agree.
      child: Container(
        key: const ValueKey('about-logo-plate'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          // 墨水屏没有彩色投影可投；留一圈阴影只会糊成一团黑。
          boxShadow: palette.eink
              ? null
              : [
                  BoxShadow(
                    color: palette.accentText.withValues(alpha: 0.20),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            'assets/images/app_logo.webp',
            width: 80,
            height: 80,
            // Decode at the display size rather than the whole 384²
            // surface, which would hold ~590 KB in the image cache for a
            // 80dp logo.
            cacheWidth: (80 * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(80, AboutPage._logoPixelWidth),
            fit: BoxFit.contain,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}

/// 头部应用名与一行定位副标题。
class _AboutHeading extends StatelessWidget {
  const _AboutHeading();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      children: [
        Text(
          '什锦铺',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            height: 1.25,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.3,
            color: palette.ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '小说 / 短剧 / 漫剧 / 漫画 / 听书聚合客户端',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.muted, fontSize: 13),
        ),
      ],
    );
  }
}

/// 信息卡：版本（点按复制）、检查更新、开源许可、源码与反馈。
class _AboutInfoCard extends StatelessWidget {
  const _AboutInfoCard();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SettingsGroupCard(
      children: [
        SettingsRow(
          icon: LucideIcons.badge_check,
          iconTile: true,
          title: '当前版本',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AboutPage.versionText,
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
              const SizedBox(width: 6),
              Icon(LucideIcons.copy, size: 15, color: palette.muted),
            ],
          ),
          onTap: () => AboutPage._copyVersion(context),
        ),
        SettingsRow(
          icon: LucideIcons.square_arrow_out_up_right,
          iconTile: true,
          title: '检查更新',
          subtitle: '前往 GitHub 发布页查看新版本',
          onTap: () => _launchExternalUrl(
            context,
            'https://github.com/ch6vip/fqapp/releases',
          ),
        ),
        SettingsRow(
          icon: LucideIcons.scale,
          iconTile: true,
          title: '开源许可',
          subtitle: 'GPL-3.0 与第三方组件许可',
          onTap: () => showLicensePage(
            context: context,
            applicationName: '什锦铺',
            applicationVersion: AboutPage.versionText,
            applicationLegalese: '什锦铺基于 GPL-3.0 协议开源，第三方组件遵循其各自的许可协议。',
          ),
        ),
        SettingsRow(
          icon: LucideIcons.code_xml,
          iconTile: true,
          title: '源代码',
          subtitle: 'github.com/ch6vip/fqapp',
          onTap: () =>
              _launchExternalUrl(context, 'https://github.com/ch6vip/fqapp'),
        ),
        SettingsRow(
          icon: LucideIcons.message_square,
          iconTile: true,
          title: '问题反馈',
          subtitle: '前往 GitHub Issues 提交',
          onTap: () => _launchExternalUrl(
            context,
            'https://github.com/ch6vip/fqapp/issues',
          ),
        ),
      ],
    );
  }
}

/// 用外部应用打开 [url]。Android 的包可见性可能让浏览器对 canLaunchUrl
/// 不可见，但仍能处理 ACTION_VIEW，所以这里不做预检查，失败统一走可见提示。
Future<void> _launchExternalUrl(BuildContext context, String url) async {
  final uri = Uri.parse(url);
  var launched = false;
  try {
    launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Report launch failures through the same visible fallback.
  }
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开链接')));
  }
}

/// 支持作者区块：单独一张卡，用爱发电品牌紫着色并配实心按钮，比普通信息行
/// 更醒目（对齐 Aether 仓库赞助区的呈现方式）。点击只用系统浏览器打开链接，
/// 不引入账号、支付、捐赠校验或统计上报；墨水屏模式下退化为黑白。
/// 爱发电是主入口（实心按钮），微信赞赏是次级入口（描边按钮，点开弹窗看码）。
class _SupportCard extends StatelessWidget {
  const _SupportCard();

  static const _sponsorUrl = 'https://afdian.com/a/ch6vip';

  /// 爱发电品牌紫，与 README 里 shields.io 徽章同色。
  static const _brandColor = Color(0xFF946CE6);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final brand = palette.eink ? palette.ink : _brandColor;
    final onBrand = palette.eink ? palette.canvas : Colors.white;
    final tint = brand.withValues(
      alpha: palette.eink ? 0.06 : (palette.dark ? 0.20 : 0.10),
    );

    return Material(
      color: tint,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SettingsGroupCard.radius),
        side: BorderSide(color: brand.withValues(alpha: 0.35), width: 0.6),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SupportHeader(brand: brand, onBrand: onBrand),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _launchExternalUrl(context, _sponsorUrl),
                icon: const Icon(LucideIcons.heart, size: 18),
                label: const Text('前往爱发电'),
                style: FilledButton.styleFrom(
                  backgroundColor: brand,
                  foregroundColor: onBrand,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => AboutPage._showWechatReward(context),
                icon: const Icon(LucideIcons.qr_code, size: 18),
                label: const Text('微信赞赏'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: brand,
                  side: BorderSide(color: brand.withValues(alpha: 0.55)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
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

/// 支持卡头部：品牌色图标块 + 标题与一句说明。
class _SupportHeader extends StatelessWidget {
  final Color brand;
  final Color onBrand;

  const _SupportHeader({required this.brand, required this.onBrand});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: brand,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(LucideIcons.hand_heart, size: 20, color: onBrand),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '支持作者',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: palette.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '如果这个项目对你有帮助，欢迎在爱发电支持我',
                style: TextStyle(fontSize: 12.5, color: palette.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
