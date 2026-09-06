import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// About page styled after PiliPlus: centered logo/name header followed by
/// grouped card rows (version, source code, feedback, ...).
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

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
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(
                Icons.local_fire_department,
                size: 52,
                color: theme.colorScheme.onPrimaryContainer,
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
              '番茄小说/短剧/漫画/听书聚合客户端',
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
                trailingText: '1.0.3 (4)',
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
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
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开链接')));
    }
  }
}
