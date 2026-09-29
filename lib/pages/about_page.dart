import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// About page styled after PiliPlus: centered logo/name header followed by
/// grouped card rows (version, source code, feedback, ...).
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  /// Display version, kept in lockstep with pubspec.yaml's
  /// `version: 1.0.64+65`. Without a package_info dependency the value is
  /// static, so test/about_version_test.dart parses the pubspec and fails the
  /// build check when the two drift apart after a version bump.
  static const versionText = '1.0.64 (65)';

  /// Pixel width of the bundled logo (assets/images/app_logo.webp). The logo
  /// is displayed at 96dp, so it only needs re-decoding above 4× DPI; clamping
  /// to the asset's real width keeps a high-DPI device from asking the decoder
  /// to upscale a surface the asset does not have.
  static const _logoPixelWidth = 384;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    return Scaffold(
      appBar: AppBar(title: const Text('关于'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const SizedBox(height: 20),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset(
                'assets/images/app_logo.webp',
                width: 96,
                height: 96,
                // Decode at the display size rather than the whole 384²
                // surface, which would hold ~590 KB in the image cache for a
                // 96dp logo.
                cacheWidth: (96 * MediaQuery.devicePixelRatioOf(context))
                    .round()
                    .clamp(96, _logoPixelWidth),
                fit: BoxFit.contain,
                excludeFromSemantics: true,
              ),
            ),
          ),
          ListTile(
            title: Text(
              '番茄小铺',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(height: 2),
            ),
            subtitle: Text(
              '番茄小说/短剧/漫剧/漫画/听书聚合客户端',
              textAlign: TextAlign.center,
              style: TextStyle(color: outline, fontSize: 13),
            ),
          ),
          const SizedBox(height: 12),
          const _AboutCard(
            children: [
              _AboutRow(
                icon: Icons.commit_outlined,
                title: '当前版本',
                trailingText: AboutPage.versionText,
              ),
            ],
          ),
          const _AboutCard(
            children: [
              _AboutRow(
                icon: Icons.info_outline,
                title: '项目介绍',
                subtitle: '旧后端()本地运行，签名/解密在手机本地完成',
              ),
              Divider(height: 1, indent: 56),
              _AboutRow(
                icon: Icons.code,
                title: 'Source Code',
                subtitle: 'github.com/ch6vip/fqapp',
                url: 'https://github.com/ch6vip/fqapp',
              ),
              Divider(height: 1, indent: 56),
              _AboutRow(
                icon: Icons.feedback_outlined,
                title: '问题反馈',
                subtitle: '前往 GitHub Issues 提交',
                url: 'https://github.com/ch6vip/fqapp/issues',
              ),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '仅限个人学习研究使用\n请遵守相关法律法规',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  final List<Widget> children;
  const _AboutCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailingText;
  final String? url;

  const _AboutRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.url,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    return ListTile(
      onTap: url == null ? null : () => _launchUrl(context, url!),
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title, style: theme.textTheme.titleMedium),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: theme.textTheme.labelMedium?.copyWith(color: outline),
            ),
      trailing: trailingText != null
          ? Text(trailingText!, style: TextStyle(fontSize: 13, color: outline))
          : url != null
          ? Icon(Icons.arrow_forward, size: 16, color: outline)
          : null,
    );
  }

  Future<void> _launchUrl(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    var launched = false;
    try {
      // Android package visibility may hide a browser from canLaunchUrl even
      // though it can handle the actual ACTION_VIEW intent.
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
}
