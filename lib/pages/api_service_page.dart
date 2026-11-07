// 本地接口服务台（fqapp 专有功能，上游没有对应页面）。
//
// Chrome follows the ported Wenku8 settings vocabulary from revision ebcd7f1:
// ArchiveFeaturePage header, ContentPanel option panels, glass switch and
// archive action rows. The backend probe, LAN sharing and copy behaviour are
// unchanged.
//
// Mechanical substitutions:
// - `SettingsScaffold` / `SettingsGroupCard` / `SettingsSwitch` / HomePalette
//   rows -> `SettingsArchivePage`, `ContentPanel`, `SettingsPanel`,
//   `SettingsLinkRow`, `GlassControls.toggle`.
// - `SettingsArchivePage` drops the back button when the nearest Navigator has
//   nothing to pop, so the Windows right pane cannot be emptied by it.
// - The status dot reads the archive `colorScheme` instead of HomePalette.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/backend_service.dart';
import '../services/lan_share_preferences.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_archive_rows.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'log_viewer_page.dart';

/// Local API service console.
///
/// The backend exposes a read-only HTTP API on loopback so external readers
/// (Legado book sources, local tooling) can consume it. There is no built-in
/// Web UI any more: this page is the only place the interface is described.
///
/// Deliberately short. Three things matter here — is it running, what address
/// do I paste elsewhere, and let me check that address actually answers. The
/// endpoint list is a reference, so it stays collapsed until asked for.
class ApiServicePage extends StatefulWidget {
  const ApiServicePage({super.key});

  @override
  State<ApiServicePage> createState() => _ApiServicePageState();
}

class _ApiServicePageState extends State<ApiServicePage> {
  String _status = '';
  bool _checking = false;
  bool _switching = false;
  bool _lanShare = false;
  bool _showEndpoints = false;

  /// Device-pool size reported by `/health`; null until the first answer.
  int? _devices;

  /// Result of the manual connectivity check, null when never run.
  String? _probeResult;
  bool _probeOk = false;

  /// LAN addresses of this device, most likely WiFi first. Empty while sharing
  /// is off or the lookup failed.
  List<String> _lanAddresses = const [];

  @override
  void initState() {
    super.initState();
    _loadShareState();
    _refresh();
  }

  Future<void> _loadShareState() async {
    await LanSharePreferences.instance.load();
    final enabled = LanSharePreferences.instance.enabled.value;
    final addresses = enabled ? await _detectLanAddresses() : const <String>[];
    if (!mounted) return;
    setState(() {
      _lanShare = enabled;
      _lanAddresses = addresses;
    });
  }

  /// IPv4 addresses of up-link interfaces.
  ///
  /// `NetworkInterface.list` enumerates every interface, including loopback and
  /// (on Android) cellular/tunnel ones. Only usable LAN addresses are useful to
  /// show, so link-local and loopback are filtered out and the result is
  /// ordered with private ranges first.
  static Future<List<String>> _detectLanAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final found = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) found.add(address.address);
        }
      }
      found.sort((a, b) {
        int rank(String ip) => ip.startsWith('192.168.')
            ? 0
            : ip.startsWith('10.')
            ? 1
            : ip.startsWith('172.')
            ? 2
            : 3;
        return rank(a).compareTo(rank(b));
      });
      return found;
    } catch (_) {
      return const [];
    }
  }

  String get _base {
    final base = BackendService.instance.baseUrl;
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  /// Port the core is bound to, taken from [baseUrl] so the LAN rows and the
  /// loopback row cannot disagree.
  String get _listenPort {
    final parts = Uri.tryParse(_base);
    if (parts == null || parts.port == 0) return '';
    return '${parts.port}';
  }

  /// Reads `/health` once and keeps both the verdict and the device count.
  ///
  /// The count is the only real signal `/health` carries, so showing「运行中」
  /// alone threw it away. It does not touch upstream or the device pool's
  /// rotating budget, which is why the probe uses it instead of a search.
  Future<void> _refresh() async {
    if (_checking) return;
    setState(() => _checking = true);
    int? devices;
    var ok = false;
    try {
      final base = BackendService.instance.baseUrl;
      final response = await BackendService.instance.transport.send(
        'GET',
        Uri.parse('$base/health'),
        timeout: const Duration(seconds: 3),
      );
      if (response.statusCode == 200) {
        ok = true;
        try {
          final decoded = jsonDecode(utf8.decode(response.body));
          if (decoded is Map && decoded['devices'] is num) {
            devices = (decoded['devices'] as num).toInt();
          }
        } catch (_) {
          // A body we cannot parse still proves the listener answered.
        }
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _status = ok ? '运行中' : '已停止';
      _devices = devices;
      _checking = false;
    });
  }

  /// Explicit self-test: reports what the client actually got back.
  ///
  /// [refresh] keeps the row's own state quiet; this one is a deliberate action
  /// so it is allowed to say "通了 / 不通" out loud.
  Future<void> _probe() async {
    if (_checking) return;
    setState(() => _checking = true);
    String result;
    var ok = false;
    try {
      final base = BackendService.instance.baseUrl;
      final response = await BackendService.instance.transport.send(
        'GET',
        Uri.parse('$base/health'),
        timeout: const Duration(seconds: 5),
      );
      ok = response.statusCode == 200;
      result = ok ? '通了 · HTTP 200' : '返回 HTTP ${response.statusCode}';
      if (ok) {
        try {
          final decoded = jsonDecode(utf8.decode(response.body));
          if (decoded is Map && decoded['devices'] is num) {
            result =
                '通了 · HTTP 200 · ${(decoded['devices'] as num).toInt()} 个设备';
          }
        } catch (_) {}
      }
    } catch (error) {
      result = '不通 · $error';
    }
    if (!mounted) return;
    setState(() {
      _probeOk = ok;
      _probeResult = result;
      _checking = false;
    });
    await _refresh();
  }

  Future<void> _toggleLanShare(bool value) async {
    if (_switching) return;
    if (value) {
      final confirmed = await showSettingsConfirmDialog(
        context: context,
        title: '开启局域网共享',
        message:
            '同一网络下的其他设备将能访问这些接口，无需密码。\n\n'
            '开启后本地服务会重启，正在进行的请求会中断一次。',
        confirmLabel: '开启',
      );
      if (!confirmed) return;
    }
    if (!mounted) return;
    setState(() => _switching = true);
    await LanSharePreferences.instance.setEnabled(value);
    try {
      await BackendService.instance.restartForListenMode();
    } catch (_) {
      // The status row below reports it after the refresh.
    }
    final addresses = value ? await _detectLanAddresses() : const <String>[];
    if (!mounted) return;
    setState(() {
      _lanShare = value;
      _lanAddresses = addresses;
      _switching = false;
    });
    await _refresh();
  }

  Future<void> _copy(String label, String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final healthy = _status == '运行中';
    // 相对路径：根地址已经在上面的卡片里，这里再拼一遍只会让列表更难读。
    const endpoints = <(String, String, String)>[
      ('搜索', '/api/v1/search/fanqie?query=', '替换为关键词'),
      ('详情', '/api/v1/books/{book_id}', '书名、作者、简介、封面'),
      ('目录', '/api/v1/books/{book_id}/directory', '章节列表'),
      ('正文', '/api/v1/chapters/{item_id}', '章节正文与插图'),
    ];

    return SettingsArchivePage(
      title: '本地接口',
      code: 'SYSTEM / LOCAL API',
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: featurePadding(context),
            children: [
              // 状态：一行说完「跑没跑 + 几个设备 + 要不要再测一次」。
              ContentPanel(
                child: Row(
                  children: [
                    Container(
                      key: const ValueKey('api-status-dot'),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        // 运行中的状态点跟随主题前景色：墨水屏退化为纯黑。
                        color: healthy
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: AppText(
                        _devices == null ? _status : '$_status · $_devices 个设备',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    GlassTextButton(
                      onPressed: _checking ? null : _probe,
                      compact: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_checking)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            const ArchiveIcon(
                              CupertinoIcons.waveform_path_ecg,
                              size: 16,
                            ),
                          const SizedBox(width: 6),
                          const AppText('自测'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_probeResult != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 8),
                  child: AppText(
                    _probeResult!,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: _probeOk ? scheme.onSurface : scheme.error,
                    ),
                  ),
                ),

              // 地址 + 局域网开关：两者都是「怎么访问」，合成一块。
              const SizedBox(height: 14),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _addressRow(label: _lanShare ? '本机' : '地址', value: _base),
                    const Divider(height: 22),
                    Row(
                      children: [
                        ArchiveIcon(
                          _lanShare
                              ? CupertinoIcons.wifi
                              : CupertinoIcons.wifi_slash,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: AppText(
                            '局域网共享',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (_switching)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          GlassControls.toggle(
                            context,
                            value: _lanShare,
                            // 确认框还开着时不能先显示「开」：只有真正
                            // 开启成功才跟随 `_lanShare` 翻转。
                            optimistic: false,
                            semanticLabel: '局域网共享',
                            onChanged: _switching ? null : _toggleLanShare,
                          ),
                      ],
                    ),
                    if (_lanShare) ...[
                      const SizedBox(height: 10),
                      if (_lanAddresses.isEmpty)
                        const SettingsHint(
                          '未检测到局域网地址，请确认已连接 WiFi。',
                          fontSize: 12,
                        )
                      else
                        for (final ip in _lanAddresses)
                          _addressRow(
                            label: '局域网',
                            value: 'http://$ip:$_listenPort',
                          ),
                      const SizedBox(height: 4),
                      const SettingsHint(
                        '无密码，同一网络下任何设备都能读取。公共 WiFi 建议关闭。',
                        fontSize: 12,
                      ),
                    ],
                  ],
                ),
              ),

              // 接口是参考信息，默认收起；要用的人自己点开。
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: GlassTextButton(
                  compact: true,
                  onPressed: () =>
                      setState(() => _showEndpoints = !_showEndpoints),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ArchiveIcon(
                        _showEndpoints
                            ? CupertinoIcons.chevron_down
                            : CupertinoIcons.chevron_right,
                        size: 15,
                      ),
                      const SizedBox(width: 6),
                      AppText(_showEndpoints ? '隐藏接口' : '查看可用接口'),
                    ],
                  ),
                ),
              ),
              if (_showEndpoints)
                ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < endpoints.length; i++) ...[
                        if (i > 0) const Divider(height: 18),
                        _endpointRow(
                          name: endpoints[i].$1,
                          path: endpoints[i].$2,
                          hint: endpoints[i].$3,
                        ),
                      ],
                      const SizedBox(height: 10),
                      const SettingsHint(
                        '路径拼在上面的地址后面；{ } 内是变量，需替换成实际 ID。',
                        fontSize: 12,
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 14),
              ContentPanel(
                padding: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: SettingsLinkRow(
                    icon: CupertinoIcons.doc_plaintext,
                    title: '运行日志',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LogViewerPage()),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One copyable address line: label, address, copy affordance.
  Widget _addressRow({required String label, required String value}) {
    final scheme = Theme.of(context).colorScheme;
    return JellyTapSurface(
      onTap: value.isEmpty ? null : () => _copy('地址', value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: AppText(
                label,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: AppText(
                value.isEmpty ? '等待服务启动' : value,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            ArchiveIcon(
              CupertinoIcons.doc_on_doc,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// One endpoint: name, relative path, one-line purpose.
  Widget _endpointRow({
    required String name,
    required String path,
    required String hint,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return JellyTapSurface(
      onTap: () => _copy(name, '$_base$path'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppText(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: AppText(
                    'GET',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            AppText(path, style: const TextStyle(fontFamily: 'monospace')),
            AppText(
              hint,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
