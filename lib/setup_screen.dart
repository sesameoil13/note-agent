import 'package:flutter/material.dart';

import 'connection.dart';
import 'connection_screen.dart';
import 'budget_panel.dart';
import 'note_workspace.dart';
import 'workspace_platform.dart';

enum SetupAction { chooseVault, record }

/// A recoverable, optional guide. External checks remain explicitly attributed
/// to the user; no checklist action changes a remote vault or grants OS access.
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.workspace,
    required this.connection,
  });
  final NoteWorkspace? workspace;
  final WorkspaceConnection connection;
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  bool _busy = false;
  String? _error;
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      _error = '未能保存核对记录，请重试。原有笔记与设置仍保留。';
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _check(SetupCheck check, String text, {bool enabled = true}) {
    final workspace = widget.workspace!;
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      value: workspace.setup.isReported(check),
      onChanged: _busy || !enabled
          ? null
          : (value) => _run(() => workspace.reportSetupCheck(check, value!)),
      title: Text(text),
      subtitle: workspace.setup.reports[check] == null
          ? null
          : const Text('你已核对 · 可取消后重新核对'),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }

  Future<void> _confirmSlot() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('单独确认远程名额切换'),
        content: Text(
          '目标本地库：${widget.workspace!.vaultStorage.displayName}\n\nStandard 只有一个远程库。请确认完整备份与可用于以后导入的旧库本地副本已独立保留。切换会影响其他设备继续同步旧库。\n\n此处只记录你的决定。随后由你在 Obsidian 内查看实际操作、再次确认并执行；App 不删除、改写旧库或操作远程名额。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不切换'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('我确认，继续到 Obsidian 核对'),
          ),
        ],
      ),
    );
    if (yes == true) await _run(widget.workspace!.confirmRemoteSlotSwitch);
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    final state = workspace?.setup;
    final budget = workspace?.budget;
    return Scaffold(
      appBar: AppBar(title: const Text('设置与首次引导')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                '从收集到自己的笔记库',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              const Text(
                '随时回来恢复设置。以下是用户核对记录，不是系统权限或 Obsidian 云端同步成功的证明。未完成设置也可在已授权的本地库保存。',
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 24),
              const Text(
                '1 / 连接与设备',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const Text(
                '第一台连接 OpenRouter。已有原设备时，从原设备生成配对码加入；不要再次启用或清除原设备身份。每台设备单独授权自己的本地库。',
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        await Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                ConnectionScreen(connection: widget.connection),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                child: const Text('连接、重新检测或配对'),
              ),
              const SizedBox(height: 24),
              const Text(
                '2 / 本地笔记库与权限',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              Text(
                workspace == null
                    ? '尚未选择本地笔记库。'
                    : '当前本地库：${workspace.vaultStorage.displayName}',
              ),
              const Text(
                '选择或重新授权文件夹只改变本机写入位置，不切换 Obsidian 远程库。取消选择会保留输入。若授权失效，重新选择同一文件夹后重试保存。',
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.pop(context, SetupAction.chooseVault),
                child: const Text('选择或重新授权本地库'),
              ),
              const Text(
                '录音时由系统请求麦克风权限；曾拒绝时，到系统设置中为 Note Agent 恢复权限，再回 App 重试。通知权限同样由系统决定；只有实际收到测试提醒后才能核对。',
              ),
              if (workspace != null) ...[
                OutlinedButton(
                  onPressed: workspace.recordingAvailable && !_busy
                      ? () => Navigator.pop(context, SetupAction.record)
                      : null,
                  child: const Text('前往本机录音测试'),
                ),
                _check(SetupCheck.microphoneTested, '我已实际录音并回放，麦克风正常'),
                _check(SetupCheck.notificationsTested, '我已在此设备实际收到测试提醒'),
                const SizedBox(height: 24),
                const Text(
                  '3 / Obsidian 核对',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const Text(
                  '先在 Obsidian 库管理中“打开文件夹为仓库”，选择这里的同一个文件夹。目录授权不会自动把库加入 Obsidian。Sync 运行、附件到达与待办状态连接分别判断。',
                ),
                OutlinedButton(
                  onPressed: _busy || workspace.notes.isEmpty
                      ? null
                      : () => _run(
                          () => WorkspacePlatform().openInObsidian(
                            workspace.notes.first.notePath,
                          ),
                        ),
                  child: const Text('在 Obsidian 打开本库笔记'),
                ),
                if (workspace.notes.isEmpty)
                  const Text('先保存一条笔记，再从这里打开核对；也可直接在 Obsidian 打开同一个文件夹。'),
                _check(
                  SetupCheck.correctVaultOpened,
                  '我已在 Obsidian 打开同一个库并核对笔记',
                ),
                _check(
                  SetupCheck.standardPlan,
                  '我已核对官方 Sync Standard：1 个远程库、单文件 5 MB、总存储 1 GB',
                ),
                _check(
                  SetupCheck.otherFileTypes,
                  '我已在 Sync 中启用需要的音频、PDF 与其他文件类型',
                ),
                _check(
                  SetupCheck.hiddenProperties,
                  '我已在 Obsidian 设置 → 编辑器中将文档属性显示设为隐藏',
                ),
                const SizedBox(height: 24),
                const Text(
                  '4 / 旧库备份与远程名额',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const Text(
                  '完整备份应包括所有 Markdown、截图与其他附件、隐藏的 .obsidian 文件夹及需要的其他文件。复制到与同步库分开的本地位置，打开抽查正文和图片，并核对文件数量或大小。Sync 或版本历史不能代替这份独立备份。\n保留旧库为后续 AI 导入的本地副本；本轮不会批量导入、改写或删除旧库。',
                ),
                _check(SetupCheck.backupComplete, '我已制作并检查独立的完整旧库备份'),
                _check(
                  SetupCheck.localImportCopyRetained,
                  '旧库的本地导入副本已保留，不会随远程名额切换删除',
                ),
                OutlinedButton(
                  onPressed: !_busy && state!.backupReady ? _confirmSlot : null,
                  child: const Text('单独确认远程名额切换'),
                ),
                Text(
                  state!.remoteSlotConsentAt == null
                      ? '尚未确认远程名额切换。没有旧库时可跳过这一节。'
                      : '已记录你的切换决定；实际 Obsidian 操作仍需你完成并核对。',
                ),
                _check(
                  SetupCheck.remoteSlotSwitched,
                  '我已在 Obsidian 完成切换，并核对新库及保留的旧库副本',
                  enabled: state.remoteSlotConsentAt != null,
                ),
                const SizedBox(height: 24),
                const Text(
                  '5 / 预付与月消耗',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const Text(
                  '预付余额：未知，请在 OpenRouter 账户查看。普通模型 Key 不能读取账户预付余额，App 不接收管理 Key。充值前核对实际金额、费用，并保持自动充值关闭。App 不自动充值。',
                ),
                Text(
                  budget!.connected
                      ? '本月预算：¥${(budget.limitCnyMicros / 1000000).toStringAsFixed(2)} · 保守折算消耗：¥${(budget.spentCnyMicros / 1000000).toStringAsFixed(2)}'
                      : '月预算：¥${(budget.limitCnyMicros / 1000000).toStringAsFixed(2)} · 本月实际消耗：尚未连接，未知',
                ),
                Text(budget.message),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => BudgetPanel(workspace: workspace),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                  child: const Text('打开 AI 与共享预算'),
                ),
                const Text('预付款以美元计价，可跨月使用；人民币月消耗按独立预算控制，预付有余额不代表本月可继续使用。'),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(workspace.clearSetupReports),
                  child: const Text('清除本库核对记录，重新检查'),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回收集'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
