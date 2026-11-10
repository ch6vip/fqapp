import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/backend_service.dart';
import '../../services/local_proxy_discovery.dart';
import '../../services/network_proxy_preferences.dart';
import '../wenku/wenku_ui.dart';
import 'settings_archive_rows.dart';

/// The saved policy is deployed to the Rust core before any upstream client starts.
class CoreProxySettingsPanel extends StatefulWidget {
  const CoreProxySettingsPanel({super.key, this.discover, this.applyChanges});

  final Future<List<LocalProxyCandidate>> Function()? discover;
  final Future<void> Function()? applyChanges;

  @override
  State<CoreProxySettingsPanel> createState() => _CoreProxySettingsPanelState();
}

class _CoreProxySettingsPanelState extends State<CoreProxySettingsPanel> {
  final _address = TextEditingController();
  bool _enabled = false;
  bool _loading = true;
  bool _discovering = false;
  bool _saving = false;
  bool _error = false;
  bool _loadFailed = false;
  String? _message;
  String? _addressError;
  String? _discoveryMessage;
  List<LocalProxyCandidate> _candidates = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = await NetworkProxyPreferences.instance.load();
      if (!mounted) return;
      setState(() {
        _enabled = config.enabled;
        _address.text = config.url;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
        _error = true;
        _message = '读取代理配置失败，请选择连接方式后重新保存。';
      });
    }
  }

  Future<void> _discover() async {
    if (_discovering || _saving || _loading) return;
    setState(() {
      _discovering = true;
      _candidates = const [];
      _discoveryMessage = null;
    });
    try {
      final candidates =
          await (widget.discover ?? LocalProxyDiscovery().discover)();
      if (!mounted) return;
      setState(() {
        _candidates = candidates;
        _discoveryMessage = candidates.isEmpty
            ? '未发现可用的本机代理，请先启动代理软件或手动填写地址。'
            : '点击选择代理，再保存应用。';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _discoveryMessage = '检测失败，请重试或手动填写代理地址。');
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _save() async {
    if (_loading || _saving || _discovering) return;
    final validation = _enabled
        ? NetworkProxyConfig.validateUrl(_address.text)
        : null;
    setState(() {
      _addressError = validation;
      _message = null;
    });
    if (validation != null) return;
    setState(() => _saving = true);
    var persisted = false;
    try {
      await NetworkProxyPreferences.instance.save(
        NetworkProxyConfig(enabled: _enabled, url: _address.text.trim()),
      );
      persisted = true;
      await (widget.applyChanges ??
          BackendService.instance.restartForConfiguration)();
      if (!mounted) return;
      setState(() {
        _error = false;
        _loadFailed = false;
        _message = _enabled ? '已应用，核心请求使用指定代理' : '已应用，核心请求直接连接';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _message = persisted
            ? '已保存，但核心启动失败。请检查配置后重新应用，或选择直连。'
            : '代理配置保存失败，请重试。';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = _loading || _saving || _discovering;
    return ContentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppText(
            '核心网络代理',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          SettingsToggleRow(
            icon: CupertinoIcons.arrow_right_arrow_left,
            title: '使用指定代理',
            description: _loading
                ? '正在读取配置…'
                : _loadFailed
                ? '配置读取失败，重新保存后生效'
                : _enabled
                ? 'Rust 核心 API、加密媒体分段和视频下载统一走代理'
                : '默认直连，忽略系统代理与代理环境变量',
            value: _enabled,
            optimistic: false,
            onChanged: busy
                ? null
                : (value) => setState(() {
                    _enabled = value;
                    _message = null;
                    _addressError = null;
                  }),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('core-proxy-address'),
            controller: _address,
            enabled: _enabled && !busy,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {
              _addressError = null;
              _message = null;
            }),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: '代理地址',
              hintText: 'http://127.0.0.1:7890',
              errorText: _addressError,
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          AppText(
            '支持 HTTP、HTTPS、SOCKS5 / SOCKS5h，无需账号密码。代理故障时直接报错，不回退直连。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: GlassTextButton(
              onPressed: busy ? null : _discover,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_discovering)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const ArchiveIcon(CupertinoIcons.search, size: 16),
                  const SizedBox(width: 8),
                  AppText(_discovering ? '正在检测…' : '检测本机代理'),
                ],
              ),
            ),
          ),
          AppText(
            '检测 Windows 本机监听端口，系统代理关闭时也可发现。检测仅访问本机。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (_discoveryMessage != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: AppText(
                _discoveryMessage!,
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
            ),
          ],
          for (final candidate in _candidates)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        _enabled = true;
                        _address.text = candidate.url;
                        _addressError = null;
                        _message = null;
                      }),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(candidate.label),
                  ),
                ),
              ),
            ),
          const Divider(height: 24),
          AppText(
            '保存后重启核心，进行中的核心请求会中断一次。Flutter 下载器、网页登录与非加密播放不受此设置控制。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: GlassTextButton(
              onPressed: busy ? null : _save,
              child: AppText(_saving ? '正在应用…' : '保存并应用'),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: AppText(
                _message!,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: _error ? scheme.error : scheme.onSurface,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
