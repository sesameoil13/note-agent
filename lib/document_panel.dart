import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'note_workspace.dart';
import 'workspace_platform.dart';

class PdfImportButton extends StatefulWidget {
  const PdfImportButton({
    super.key,
    required this.workspace,
    required this.onChanged,
  });
  final NoteWorkspace workspace;
  final ValueChanged<String?> onChanged;
  @override
  State<PdfImportButton> createState() => _PdfImportButtonState();
}

class _PdfImportButtonState extends State<PdfImportButton> {
  final _platform = WorkspacePlatform();
  bool _busy = false;
  Timer? _refresh;
  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    File? selected;
    try {
      selected = await _platform.chooseSourceFile(pdfOnly: true);
      if (selected == null) return;
      final before = widget.workspace.notes.map((n) => n.id).toSet();
      var selectedNote = false;
      void refresh() {
        if (!mounted) return;
        final added = widget.workspace.notes
            .where((n) => !before.contains(n.id) && n.document != null)
            .firstOrNull;
        widget.onChanged(!selectedNote && added != null ? added.id : null);
        if (added != null) selectedNote = true;
      }

      final operation = widget.workspace.importPdf(original: selected);
      _refresh = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => refresh(),
      );
      await operation;
      refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is ArgumentError
                  ? error.message.toString()
                  : 'PDF 导入未完成，请查看原件保存状态。$error',
            ),
          ),
        );
      }
    } finally {
      _refresh?.cancel();
      if (selected != null) {
        try {
          await _platform.releaseSourceFile(selected);
        } catch (_) {
          /* Private original is retained separately. */
        }
      }
      if (mounted) {
        setState(() => _busy = false);
        widget.onChanged(null);
      }
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: _busy || !_platform.supportsSourceFiles ? null : _import,
    icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
    label: Text(_busy ? '正在导入 PDF…' : '导入 PDF'),
  );
}

/// Extraction status lives under 来源, preserving the ordinary note's three
/// sections. Source retention, extraction, and Sync remain distinct statuses.
class DocumentStatusView extends StatefulWidget {
  const DocumentStatusView({
    super.key,
    required this.workspace,
    required this.note,
    required this.onChanged,
  });
  final NoteWorkspace workspace;
  final WorkspaceNote note;
  final VoidCallback onChanged;
  @override
  State<DocumentStatusView> createState() => _DocumentStatusViewState();
}

class _DocumentStatusViewState extends State<DocumentStatusView> {
  final _platform = WorkspacePlatform();
  bool _busy = false;
  Timer? _refresh;
  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    _refresh = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) widget.onChanged();
    });
    File? selected;
    try {
      if (widget.note.document!.attachmentId == null) {
        selected = await _platform.chooseSourceFile(pdfOnly: true);
        if (selected == null) return;
      }
      await widget.workspace.retryDocumentExtraction(
        widget.note.id,
        original: selected,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('提取未完成，原件继续保留。$error')));
      }
    } finally {
      _refresh?.cancel();
      if (selected != null) {
        try {
          await _platform.releaseSourceFile(selected);
        } catch (_) {
          /* Private original is retained separately. */
        }
      }
      if (mounted) {
        setState(() => _busy = false);
        widget.onChanged();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.note.document!;
    final result = doc.result;
    final active = doc.status == DocumentImportStatus.extracting;
    final saving = doc.status == DocumentImportStatus.savingOriginal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          saving
              ? '正在保留原件；尚未提取正文。'
              : active
              ? '原件已保留，正在本机提取；可继续收集文字。'
              : result?.summary ?? doc.error ?? '尚未提取正文。',
        ),
        if (doc.error != null && result != null) Text(doc.error!),
        for (final problem in result?.problems ?? <DocumentProblem>[])
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${problem.page == null ? '' : '第 ${problem.page}${problem.lastPage == null ? '' : '–${problem.lastPage}'} 页：'}${problem.message}',
            ),
          ),
        if (active)
          TextButton(
            onPressed: () =>
                widget.workspace.cancelDocumentExtraction(widget.note.id),
            child: const Text('停止后续页面提取'),
          ),
        if (!active && !saving)
          OutlinedButton(
            onPressed: _busy ? null : _retry,
            child: Text(
              doc.attachmentId == null
                  ? '重新选择 PDF'
                  : doc.status == DocumentImportStatus.writePending
                  ? '重试写入提取结果'
                  : '重新提取 PDF',
            ),
          ),
      ],
    );
  }
}
