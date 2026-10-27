import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'connection.dart';
import 'secure_connection_field.dart';

/// The only UI that accepts the service Key. Secret text is never reflected in status.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key, required this.connection});
  final WorkspaceConnection connection;
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _key = TextEditingController();
  final _name = TextEditingController(text: '我的设备');
  final _activation = TextEditingController();
  final _code = TextEditingController();
  bool _busy = true;
  bool _confirmed = false;
  String? _error;
  WorkspaceConnection get connection => widget.connection;
  @override
  void initState() {
    super.initState();
    _run(connection.restore);
  }

  @override
  void dispose() {
    for (final controller in [_key, _name, _activation, _code]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await action();
    } on ConnectionFailure catch (error) {
      _error = error.message;
    } on PlatformException {
      _error = '系统安全存储暂时不可用，请解锁设备后重试。';
    } catch (_) {
      _error = '操作未完成，原有设置已保留。请重试。';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _confirmed = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pair = connection.pairing;
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接与设备'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                '一个入口，留在自己的设备。',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              const Text(
                '先连接 OpenRouter，再让其他设备安全加入。每台设备仍需自行授权笔记库、麦克风和通知。',
                style: TextStyle(height: 1.6),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 32),
              const Text(
                'OpenRouter',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                connection.state.message,
                style: const TextStyle(height: 1.6),
              ),
              const SizedBox(height: 16),
              SecureConnectionField(
                controller: _key,
                enabled: !_busy,
                label: connection.state.hasKey
                    ? '替换 OpenRouter API Key'
                    : 'OpenRouter API Key',
                actionLabel: connection.state.hasKey
                    ? '替换 OpenRouter API Key'
                    : null,
                helperText: '仅存入本机系统安全存储；连接检测不调用收费模型。',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await connection.connectAi(_key.text);
                            _key.clear();
                          }),
                    child: const Text('检测并安全保存'),
                  ),
                  if (connection.state.hasKey)
                    OutlinedButton(
                      onPressed: _busy ? null : () => _run(connection.checkAi),
                      child: const Text('重新检测'),
                    ),
                  if (connection.state.hasKey)
                    TextButton(
                      onPressed: _busy ? null : _removeKey,
                      child: const Text('移除本机 Key'),
                    ),
                ],
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 24),
              const Text(
                '设备配对',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(pair.message, style: const TextStyle(height: 1.6)),
              if (pair.deviceName != null) ...[
                const SizedBox(height: 8),
                Text(
                  '当前设备：${pair.deviceName} · ${pair.role == 'owner' ? '原设备' : '已加入设备'}',
                ),
              ],
              if (pair.role == null && pair.phase != 'waiting') ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: '这台设备的名称'),
                ),
                const SizedBox(height: 16),
                const Text(
                  '第一台设备',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (connection.pairingServiceConfigured) ...[
                  const Text(
                    '首次启用码由本产品的首次设置提供，只能建立一个原设备身份；不是托管账户凭据。',
                    style: TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  SecureConnectionField(
                    controller: _activation,
                    enabled: !_busy,
                    label: '首次启用码',
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: _busy || !connection.state.hasKey
                          ? null
                          : () => _run(() async {
                              await connection.activatePairing(
                                setupToken: _activation.text,
                                deviceName: _name.text,
                              );
                              _activation.clear();
                            }),
                      child: const Text('启用此原设备'),
                    ),
                  ),
                ] else
                  const Text(
                    '配对服务准备完成后即可启用；当前仍可连接 AI 服务和保存本机笔记。',
                    style: TextStyle(height: 1.6),
                  ),
                const SizedBox(height: 24),
                const Text(
                  '其他设备',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '从原设备复制的完整配对码'),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await connection.joinPairing(
                              _code.text,
                              deviceName: _name.text,
                            );
                            _code.clear();
                          }),
                    child: const Text('请求加入'),
                  ),
                ),
              ],
              if (pair.role == 'owner' && pair.phase == 'ready') ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(connection.createPairing),
                    child: const Text('生成一次性配对码'),
                  ),
                ),
              ],
              if (pair.code != null) ...[
                const SizedBox(height: 16),
                const Text(
                  '请通过自己的安全渠道直接传给另一台设备。配对码含一次性秘密，请勿公开。',
                  style: TextStyle(height: 1.6),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  pair.code!,
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                ),
                if (pair.expiresAt != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '有效期至 ${pair.expiresAt!.toLocal().toString().substring(0, 19)}',
                  ),
                ],
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(text: pair.code!),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制一次性配对码。')),
                              );
                            }
                          },
                    icon: const Icon(Icons.copy),
                    label: const Text('复制配对码'),
                  ),
                ),
              ],
              if (pair.verificationCode != null) ...[
                const SizedBox(height: 24),
                if (pair.requestDeviceName != null)
                  Text('请求设备：${pair.requestDeviceName}'),
                const SizedBox(height: 8),
                const Text('两台设备上的验证码必须一致。'),
                const SizedBox(height: 8),
                SelectableText(
                  pair.verificationCode!,
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 6,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              if (pair.phase == 'approval') ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _confirmed,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _confirmed = value ?? false),
                  title: const Text('已在自己的两台设备核对相同验证码'),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _busy || !_confirmed
                        ? null
                        : () => _run(
                            () => connection.approvePairing(
                              verificationCode: pair.verificationCode!,
                            ),
                          ),
                    child: const Text('批准并安全传递配置'),
                  ),
                ),
              ],
              if ([
                'inviting',
                'waiting',
                'approval',
                'approved',
              ].contains(pair.phase)) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(connection.refreshPairing),
                      child: const Text('刷新配对状态'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(connection.cancelPairing),
                      child: const Text('取消本次配对'),
                    ),
                  ],
                ),
              ] else if (pair.role != null) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(connection.refreshPairing),
                    child: const Text('检测设备连接'),
                  ),
                ),
              ],
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text(
                '配对完成不表示笔记已同步。笔记与附件继续由官方 Obsidian Sync 处理。',
                style: TextStyle(height: 1.6),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _removeKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除本机 Key？'),
        content: const Text('本机笔记和其他设备的 Key 会保留。此设备需要重新连接后才能处理云端任务。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(connection.disconnectAi);
    }
  }
}
