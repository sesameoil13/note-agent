import 'package:flutter/material.dart';

import 'note_workspace.dart';

String actionReasonLabel(String reason) => switch (reason) {
  'quote' => '引用内容',
  'hypothesis' => '假设表达',
  'negated' => '否定表达',
  'unclearResponsibility' => '责任人不明',
  'none' => '明确行动',
  _ => '行动含义待核对',
};

String actionTimeLabel(WorkspaceAction a) => switch (a.timeStatus) {
  ActionTimeStatus.absent => '未提供时间',
  ActionTimeStatus.unresolved => '时间待确认：${a.timeExpression}',
  ActionTimeStatus.explicit => '原文时间：${a.timeExpression}',
};

class PendingActionsScreen extends StatefulWidget {
  const PendingActionsScreen({super.key, required this.workspace});
  final NoteWorkspace workspace;
  @override
  State<PendingActionsScreen> createState() => _PendingActionsScreenState();
}

class _PendingActionsScreenState extends State<PendingActionsScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('待确认行动与主题')),
    body: ListView(
      children: [
        if (widget.workspace.pendingConfirmationNotes.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('没有待确认内容。')),
        for (final suggestion in widget.workspace.pendingTopicSuggestions)
          _TopicDecisionTile(
            workspace: widget.workspace,
            suggestion: suggestion,
            onChanged: () {
              if (mounted) setState(() {});
            },
          ),
        for (final n in widget.workspace.pendingActionNotes)
          ListTile(
            title: Text(n.title),
            subtitle: const Text('行动未确认前不启动提醒'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ActionConfirmationScreen(
                    workspace: widget.workspace,
                    noteId: n.id,
                  ),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
      ],
    ),
  );
}

class ActionConfirmationScreen extends StatefulWidget {
  const ActionConfirmationScreen({
    super.key,
    required this.workspace,
    required this.noteId,
  });
  final NoteWorkspace workspace;
  final String noteId;
  @override
  State<ActionConfirmationScreen> createState() =>
      _ActionConfirmationScreenState();
}

class _ActionEdit {
  _ActionEdit(WorkspaceAction a)
    : original = a,
      text = TextEditingController(text: a.text),
      time = TextEditingController(text: a.timeExpression),
      confirmed = a.actionConfirmed,
      timeStatus = a.timeStatus;
  final WorkspaceAction original;
  final TextEditingController text, time;
  bool confirmed;
  ActionTimeStatus timeStatus;
  void dispose() {
    text.dispose();
    time.dispose();
  }

  WorkspaceAction get value => WorkspaceAction(
    id: original.id,
    text: text.text,
    decision: confirmed ? ActionDecision.confirmed : ActionDecision.pending,
    reason: original.reason,
    timeExpression: time.text,
    timeStatus: timeStatus,
  );
}

class _ActionConfirmationScreenState extends State<ActionConfirmationScreen> {
  WorkspaceNote get note =>
      widget.workspace.notes.firstWhere((n) => n.id == widget.noteId);
  late final TextEditingController body;
  final edits = <_ActionEdit>[];
  bool busy = false;
  String? error;
  bool get locked => busy || note.actionSavePending;
  @override
  void initState() {
    super.initState();
    body = TextEditingController(text: note.text);
    edits.addAll(note.actions.map(_ActionEdit.new));
    if (edits.isEmpty) edits.add(_ActionEdit(const WorkspaceAction(text: '')));
  }

  @override
  void dispose() {
    body.dispose();
    for (final e in edits) {
      e.dispose();
    }
    super.dispose();
  }

  Future<void> save(NoteKind kind) async {
    if (busy) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (note.actionSavePending) {
        await widget.workspace.retryNoteActionSave(note.id);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      await widget.workspace.resolveNoteActions(
        note.id,
        kind: kind,
        actions: kind == NoteKind.ordinary
            ? []
            : edits.map((e) => e.value).toList(),
        body: kind == NoteKind.ordinary ? null : body.text,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is ArgumentError
              ? '${e.message}'
              : '修正尚未保存，原文及原笔记保留。请核对内容后重试；不会调用模型或释放未知费用。';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('修正类型与行动')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(note.title, style: Theme.of(context).textTheme.titleLarge),
        if (note.actionSavePending) const Text('上次修正尚未写入。先重试完成保存，再继续修改。'),
        const SizedBox(height: 12),
        const Text(
          '本页决定仅在本机保存，不调用模型。确认行动与确认时间分开；行动确认后按明确时间或默认时间安排提醒，可在“提醒与默认时间”调整。',
        ),
        OutlinedButton(
          onPressed: locked ? null : () => save(NoteKind.ordinary),
          child: const Text('仅保留为普通笔记'),
        ),
        ExpansionTile(
          title: const Text('查看完整原文'),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(note.originalText),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: body,
          enabled: !locked,
          maxLines: 4,
          decoration: const InputDecoration(labelText: '待办摘要'),
        ),
        for (final e in edits)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(actionReasonLabel(e.original.reason)),
                TextField(
                  controller: e.text,
                  enabled: !locked,
                  maxLength: 500,
                  decoration: const InputDecoration(labelText: '行动内容'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('确认由我执行'),
                  subtitle: Text(e.confirmed ? '行动已确认；时间可另行完善' : '待确认，不启动提醒'),
                  value: e.confirmed,
                  onChanged: locked
                      ? null
                      : (v) => setState(() => e.confirmed = v!),
                ),
                TextField(
                  controller: e.time,
                  enabled: !locked,
                  maxLength: 200,
                  onChanged: (v) => setState(
                    () => e.timeStatus = v.trim().isEmpty
                        ? ActionTimeStatus.absent
                        : ActionTimeStatus.unresolved,
                  ),
                  decoration: const InputDecoration(labelText: '时间表达（可留空）'),
                ),
                DropdownButtonFormField<ActionTimeStatus>(
                  initialValue: e.timeStatus,
                  key: ValueKey((e, e.timeStatus)),
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                      value: ActionTimeStatus.absent,
                      child: Text('未提供时间'),
                    ),
                    DropdownMenuItem(
                      value: ActionTimeStatus.unresolved,
                      child: Text('时间待确认'),
                    ),
                    DropdownMenuItem(
                      value: ActionTimeStatus.explicit,
                      child: Text('明确时间表达'),
                    ),
                  ],
                  onChanged: locked
                      ? null
                      : (v) => setState(() => e.timeStatus = v!),
                ),
                TextButton(
                  onPressed: locked
                      ? null
                      : () => setState(() {
                          edits.remove(e);
                          e.dispose();
                        }),
                  child: const Text('移除此项行动'),
                ),
              ],
            ),
          ),
        if (edits.length < 20)
          OutlinedButton(
            onPressed: locked
                ? null
                : () => setState(
                    () =>
                        edits.add(_ActionEdit(const WorkspaceAction(text: ''))),
                  ),
            child: const Text('添加行动'),
          ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        FilledButton(
          onPressed: busy ? null : () => save(NoteKind.todo),
          child: Text(note.actionSavePending ? '重试保存修正' : '保存修正（不调用模型）'),
        ),
      ],
    ),
  );
}

class _TopicDecisionTile extends StatefulWidget {
  const _TopicDecisionTile({
    required this.workspace,
    required this.suggestion,
    required this.onChanged,
  });
  final NoteWorkspace workspace;
  final WorkspaceTopicSuggestion suggestion;
  final VoidCallback onChanged;
  @override
  State<_TopicDecisionTile> createState() => _TopicDecisionTileState();
}

class _TopicDecisionTileState extends State<_TopicDecisionTile> {
  bool busy = false;
  String? error;
  Future<void> decide(bool approve) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (approve) {
        await widget.workspace.confirmTopicSuggestion(widget.suggestion.id);
      } else {
        await widget.workspace.ignoreTopicSuggestion(widget.suggestion.id);
      }
      widget.onChanged();
    } catch (_) {
      if (mounted) {
        setState(() {
          error = '主题决定尚未保存，请重试。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('新主题：${widget.suggestion.title}'),
        Text(widget.suggestion.reason),
        Text(
          '来自：${widget.workspace.notes.firstWhere((n) => n.id == widget.suggestion.noteId).title}',
        ),
        if (error != null) Text(error!),
        Wrap(
          spacing: 12,
          children: [
            OutlinedButton(
              onPressed: busy ? null : () => decide(true),
              child: Text(
                widget.suggestion.creationStarted ? '重试完成主题创建' : '确认创建主题',
              ),
            ),
            TextButton(
              onPressed: busy || widget.suggestion.creationStarted
                  ? null
                  : () => decide(false),
              child: const Text('忽略主题建议'),
            ),
          ],
        ),
      ],
    ),
  );
}
