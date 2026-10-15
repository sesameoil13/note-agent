import 'dart:io';

import 'package:flutter/material.dart';

import 'note_workspace.dart';
import 'sync_panel.dart';
import 'workspace_platform.dart';

/// The same durable workspace actions drive the native picker and headless tests.
class AttachmentSources extends StatefulWidget {
  const AttachmentSources({
    super.key,
    required this.workspace,
    required this.noteId,
    required this.onChanged,
  });
  final NoteWorkspace workspace;
  final String noteId;
  final VoidCallback onChanged;

  @override
  State<AttachmentSources> createState() => _AttachmentSourcesState();
}

class _AttachmentSourcesState extends State<AttachmentSources> {
  final _platform = WorkspacePlatform();
  bool _busy = false;
  String? _error;

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is ArgumentError
              ? error.message.toString()
              : '操作未完成，原件继续保留。$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onChanged();
    }
  }

  Future<void> _pick({WorkspaceAttachment? attachment}) => _perform(() async {
    File? selected;
    try {
      selected = await _platform.chooseSourceFile();
      if (selected == null) return;
      if (attachment == null) {
        await widget.workspace.attachFile(
          noteId: widget.noteId,
          original: selected,
        );
      } else {
        await widget.workspace.chooseAttachmentCopy(
          attachmentId: attachment.id,
          copy: selected,
        );
      }
    } finally {
      if (selected != null) {
        try {
          await _platform.releaseSourceFile(selected);
        } catch (_) {
          /* Source already copied privately. */
        }
      }
    }
  });

  String _status(WorkspaceAttachment item) => switch (item.status) {
    AttachmentStatus.localSaved =>
      item.copyName == null ? '本机已写入 · 笔记同步尚未核实' : '精简副本本机已写入 · 原件仅本机，未同步',
    AttachmentStatus.exceedsFileLimit => '超过 Standard 5 MB · 原件仅本机，未同步',
    AttachmentStatus.retainedLocal => '已选择仅保留本机 · 原件未同步',
    AttachmentStatus.exportPending => '原件本机已保留 · 等待写入笔记库',
    AttachmentStatus.exportFailed =>
      item.vaultCopyPublished
          ? '本机笔记库已有副本 · 来源链接未完成，云端尚未核实'
          : '原件本机已保留 · 笔记库写入未完成',
  };

  Future<void> _choices(WorkspaceAttachment item) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(item.originalName),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${sourceSize(item.originalByteLength)} · ${_status(item)}'),
              const SizedBox(height: 16),
              const Text('可先在音频或文档工具中制作有效的压缩副本，再在这里选择。原件会继续保留；请核对副本是否完整。'),
              const SizedBox(height: 16),
              if (!item.vaultCopyPublished)
                OutlinedButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    _perform(() async {
                      await widget.workspace.retainAttachmentLocally(item.id);
                    });
                  },
                  child: const Text('仅保留本机'),
                ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _platform.supportsSourceFiles
                    ? () {
                        Navigator.pop(dialogContext);
                        _pick(attachment: item);
                      }
                    : null,
                child: const Text('选择精简副本'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _perform(
                    () => _platform.revealLocalSource(item.originalPath),
                  );
                },
                child: const Text('查看本机原件'),
              ),
              if (item.status == AttachmentStatus.exportFailed) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    _perform(() async {
                      await widget.workspace.retryAttachmentExport(item.id);
                    });
                  },
                  child: const Text('重试写入附件'),
                ),
              ],
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  showSyncStorage(context, widget.workspace, _platform);
                },
                child: const Text('套餐与容量说明'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final attachments = widget.workspace.attachments.where(
      (item) => item.noteId == widget.noteId,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in attachments) ...[
          const SizedBox(height: 16),
          Text('${item.originalName} · ${sourceSize(item.originalByteLength)}'),
          const SizedBox(height: 8),
          Text(_status(item)),
          if (item.error != null) Text(item.error!),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy ? null : () => _choices(item),
              child: const Text('处理附件'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy || !_platform.supportsSourceFiles
                ? null
                : () => _pick(),
            icon: const Icon(Icons.attach_file, size: 16),
            label: Text(_busy ? '正在保留原件…' : '添加附件'),
          ),
        ),
        if (!_platform.supportsSourceFiles)
          const Text('此平台的附件选择尚未接入，现有文字收集仍可使用。'),
        if (_error != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
      ],
    );
  }
}
