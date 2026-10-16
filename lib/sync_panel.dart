import 'package:flutter/material.dart';

import 'note_workspace.dart';
import 'workspace_platform.dart';

class NoteSyncSummary extends StatelessWidget {
  const NoteSyncSummary({super.key, required this.note});
  final WorkspaceNote note;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        note.syncStatus == NoteSyncStatus.notPublished
            ? '笔记同步：等待本机写入'
            : '笔记同步：尚未核实',
      ),
      const SizedBox(height: 4),
      const Text('待办状态同步：尚未连接'),
      if (note.syncStatus == NoteSyncStatus.attachmentBlocked) ...[
        const SizedBox(height: 4),
        const Text('部分原件仅本机，未同步'),
      ],
    ],
  );
}

String sourceSize(int bytes) {
  if (bytes < 1000) return '$bytes 字节';
  if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} KB';
  if (bytes < 1000000000) return '${(bytes / 1000000).toStringAsFixed(2)} MB';
  return '${(bytes / 1000000000).toStringAsFixed(2)} GB';
}

Future<void> showSyncStorage(
  BuildContext context,
  NoteWorkspace workspace,
  WorkspacePlatform platform,
) async {
  final storage = await workspace.inspectSyncStorage();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('同步与存储'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Obsidian Sync Standard\n单文件 5 MB · 账户总存储 1 GB · 1 个远程库',
              ),
              const SizedBox(height: 16),
              Text(
                storage.localVaultBytes == null
                    ? '本机笔记库大小：暂不可读取'
                    : '本机笔记库文件：约 ${sourceSize(storage.localVaultBytes!)}',
              ),
              if (storage.localVaultExceedsAccountLimit) ...[
                const SizedBox(height: 8),
                const Text('本机文件合计已超过 Standard 账户总存储上限。请到 Obsidian 核对远端用量。'),
              ],
              const SizedBox(height: 16),
              const Text('远端用量与剩余容量：未知。版本历史和附件也占用远端空间，本机文件大小不能证明云端有足够空间。'),
              const SizedBox(height: 16),
              const Text(
                'Obsidian 运行时才会同步。在 Obsidian 设置 → Sync 核对存储用量，并启用所需的音频、PDF 和其他文件类型。打开 Obsidian 不代表其他设备已收到笔记。',
              ),
              const SizedBox(height: 16),
              const Text(
                '超限原件继续留在本机。可在来源中选择已制作好的精简副本；请自行核对副本内容。套餐说明提供官方处理方向，是否付费由你另行决定。',
              ),
              const SizedBox(height: 16),
              const Text('App 按 5,000,000 字节保守检查单文件。更换远程库或旧库名额需要单独决定。'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              await platform.openSyncPlans();
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('无法打开官方说明，请稍后重试。')),
                );
              }
            }
          },
          child: const Text('官方套餐说明'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
