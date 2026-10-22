part of 'note_workspace.dart';

enum NoteKind { ordinary, todo }

enum ActionDecision { pending, confirmed }

enum ActionTimeStatus { absent, unresolved, explicit }

/// Action certainty is independent of the time interpretation. This is a gate
/// for the later reminder module, not a claim that a notification is scheduled.
class WorkspaceAction {
  const WorkspaceAction({
    this.id = '',
    required this.text,
    this.decision = ActionDecision.pending,
    this.reason = 'unclearAction',
    this.timeExpression = '',
    this.timeStatus = ActionTimeStatus.absent,
  });
  final String id, text, reason, timeExpression;
  final ActionDecision decision;
  final ActionTimeStatus timeStatus;
  bool get actionConfirmed => decision == ActionDecision.confirmed;
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'decision': decision.name,
    'reason': reason,
    'timeExpression': timeExpression,
    'timeStatus': timeStatus.name,
  };
  factory WorkspaceAction.fromJson(Map<String, dynamic> v) => WorkspaceAction(
    id: v['id'] as String,
    text: v['text'] as String,
    decision: ActionDecision.values.byName(v['decision'] as String),
    reason: v['reason'] as String,
    timeExpression: v['timeExpression'] as String,
    timeStatus: ActionTimeStatus.values.byName(v['timeStatus'] as String),
  );
}

class NotePresentation {
  const NotePresentation({
    this.kind = NoteKind.ordinary,
    this.actions = const [],
    this.original,
    this.userDecided = false,
  });
  final NoteKind kind;
  final List<WorkspaceAction> actions;
  final String? original;
  final bool userDecided;
  bool get needsConfirmation => actions.any((a) => !a.actionConfirmed);
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'actions': actions.map((a) => a.toJson()).toList(),
    'original': original,
    'userDecided': userDecided,
  };
}

NotePresentation _presentation(String? raw) {
  if (raw == null) return const NotePresentation();
  final v = jsonDecode(raw) as Map<String, dynamic>;
  return NotePresentation(
    kind: NoteKind.values.byName(v['kind'] as String),
    original: v['original'] as String?,
    userDecided: v['userDecided'] == true,
    actions: List.unmodifiable(
      (v['actions'] as List).map(
        (a) => WorkspaceAction.fromJson((a as Map).cast<String, dynamic>()),
      ),
    ),
  );
}

extension _WorkspaceActions on NoteWorkspace {
  bool _hasActionChange(String noteId) => _database.select(
    'SELECT note_id FROM note_action_changes WHERE note_id=? AND vault=?',
    [noteId, vaultStorage.identity],
  ).isNotEmpty;
  Future<WorkspaceNote> _resolveActions(
    String noteId, {
    required NoteKind kind,
    required List<WorkspaceAction> actions,
    String? body,
  }) async {
    if (_hasAssociationChange(noteId)) throw StateError('关联修改尚未写入，请先重试保存关联。');
    if (_hasActionChange(noteId)) {
      throw StateError('上次行动修正尚未写入，请先重试保存修正。');
    }
    final note = notes.firstWhere((n) => n.id == noteId);
    if (note.status != NoteStatus.localSaved || _renamePlan(noteId) != null) {
      throw StateError('请先完成笔记库写入，再确认行动。');
    }
    if ((kind == NoteKind.ordinary && actions.isNotEmpty) ||
        (kind == NoteKind.todo && (actions.isEmpty || actions.length > 20))) {
      throw ArgumentError('普通笔记不含待办；待办笔记需要 1–20 项行动。');
    }
    final ids = <String>{};
    final resolved = <WorkspaceAction>[];
    for (final action in actions) {
      final id = action.id.isEmpty ? _createId() : action.id;
      if (!ids.add(id) ||
          action.text.trim().isEmpty ||
          action.text.length > 500 ||
          RegExp(r'[\x00-\x1f]').hasMatch(action.text) ||
          ![
            'none',
            'quote',
            'hypothesis',
            'negated',
            'unclearResponsibility',
            'unclearAction',
          ].contains(action.reason) ||
          action.timeExpression.length > 200 ||
          RegExp(r'[\x00-\x1f]').hasMatch(action.timeExpression) ||
          (action.timeStatus == ActionTimeStatus.explicit &&
              action.timeExpression.trim().isEmpty) ||
          (action.timeStatus == ActionTimeStatus.absent &&
              action.timeExpression.isNotEmpty)) {
        throw ArgumentError('请核对行动内容、身份与时间表达。');
      }
      resolved.add(
        WorkspaceAction(
          id: id,
          text: action.text.trim(),
          decision: action.decision,
          reason: action.reason,
          timeExpression: action.timeExpression,
          timeStatus: action.timeStatus,
        ),
      );
    }
    final text =
        body ?? (kind == NoteKind.ordinary ? note.originalText : note.text);
    if (text.trim().isEmpty || text.length > 12000 || text.contains('\u0000')) {
      throw ArgumentError('请保留有效的正文或摘要。');
    }
    final presentation = NotePresentation(
      kind: kind,
      actions: List.unmodifiable(resolved),
      original: note.originalText,
      userDecided: true,
    );
    final now = _clock();
    final next = WorkspaceNote(
      id: note.id,
      title: note.title,
      text: text,
      createdAt: note.createdAt,
      modifiedAt: now,
      notePath: note.notePath,
      sourcePath: note.sourcePath,
      status: note.status,
      document: note.document,
      attachments: note.attachments,
      presentation: presentation,
    );
    // Preserve existing association and source entries (including attachments),
    // while refusing to replace an externally edited body or task section.
    const anchor = '\n## 关联\n';
    final expected = _markdown(note);
    final before = await vaultStorage.readText(
      vaultStorage.relativePath(note.notePath),
    );
    final position = before.indexOf(anchor);
    if (position < 0 ||
        position != before.lastIndexOf(anchor) ||
        before.substring(0, position) != expected.split(anchor).first) {
      throw const FileSystemException('笔记内容已在其他位置修改，未覆盖；请先核对。');
    }
    var after =
        _markdown(next).split(anchor).first + before.substring(position);
    final oldTime =
        '\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(note.modifiedAt)}\n';
    if (after.endsWith(oldTime)) {
      after =
          '${after.substring(0, after.length - oldTime.length)}\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(now)}\n';
    }
    final plan = {
      'before': before,
      'after': after,
      'body': text,
      'presentation': presentation.toJson(),
      'modifiedAt': now.toIso8601String(),
      'path': vaultStorage.relativePath(note.notePath),
      'operation': _createId(),
    };
    _database.execute(
      'INSERT INTO note_action_changes(note_id,vault,payload) VALUES (?,?,?)',
      [noteId, vaultStorage.identity, jsonEncode(plan)],
    );
    await _finishActionChange(noteId);
    return notes.firstWhere((n) => n.id == noteId);
  }

  Future<void> _finishActionChange(String noteId) async {
    final rows = _database.select(
      'SELECT payload FROM note_action_changes WHERE note_id=? AND vault=?',
      [noteId, vaultStorage.identity],
    );
    if (rows.isEmpty) return;
    final plan =
        jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    await vaultStorage.replaceText(
      plan['path'] as String,
      plan['before'] as String,
      plan['after'] as String,
      'action-${plan['operation']}',
    );
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'UPDATE notes SET body=?,modified_at=?,presentation=? WHERE id=? AND vault=?',
        [
          plan['body'],
          plan['modifiedAt'],
          jsonEncode(plan['presentation']),
          noteId,
          vaultStorage.identity,
        ],
      );
      _attachments.noteContentsChanged(noteId, plan['after'] as String);
      for (final row in _database.select(
        'SELECT id,payload FROM text_jobs WHERE note_id=? AND vault=?',
        [noteId, vaultStorage.identity],
      )) {
        final payload =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        if (payload['result'] is! Map) continue;
        payload['applyPhase'] = 'applied';
        final pending = _presentation(jsonEncode(plan['presentation']))
            .needsConfirmation;
        _database.execute(
          'UPDATE text_jobs SET payload=?,status=?,error=? WHERE id=?',
          [
            jsonEncode(payload),
            (pending
                    ? TextProcessingStatus.review
                    : payload['settled'] == true
                    ? TextProcessingStatus.completed
                    : TextProcessingStatus.costPending)
                .name,
            pending ? '行动待确认，未启动提醒。' : null,
            row['id'],
          ],
        );
      }
      _database.execute('DELETE FROM note_action_changes WHERE note_id=?', [
        noteId,
      ]);
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> _recoverActionChanges() async {
    for (final row in _database.select(
      'SELECT note_id FROM note_action_changes WHERE vault=?',
      [vaultStorage.identity],
    )) {
      try {
        await _finishActionChange(row['note_id'] as String);
      } on FileSystemException {
        /* Keep the durable plan and every original; the App reports retry failure. */
      }
    }
  }
}

// Keep model or user text on a single literal task line, never allowing injected
// Markdown headings, checkbox lines or links to masquerade as extra actions.
String _actionMarkdown(String value) => value
    .replaceAll(RegExp(r'[\r\n]'), ' ')
    .replaceAllMapped(RegExp(r'[\\`*_\[\]<>#]'), (m) => '\\${m[0]}');

String _summaryMarkdown(String value) =>
    value.split('\n').map(_actionMarkdown).join('\n');

NotePresentation _resultPresentation(
  Map<String, dynamic> result,
  String noteId,
  String original,
) {
  final actions = (result['actions'] as List?) ?? [];
  return NotePresentation(
    kind: actions.isEmpty ? NoteKind.ordinary : NoteKind.todo,
    original: original,
    actions: List.unmodifiable([
      for (var i = 0; i < actions.length; i++)
        WorkspaceAction(
          id: '$noteId-action-$i',
          text: actions[i]['text'] as String,
          decision: actions[i]['reason'] == 'none'
              ? ActionDecision.confirmed
              : ActionDecision.pending,
          reason: actions[i]['reason'] as String,
          timeExpression: actions[i]['timeExpression'] as String,
          timeStatus: ActionTimeStatus.values.byName(
            actions[i]['timeStatus'] as String,
          ),
        ),
    ]),
  );
}
