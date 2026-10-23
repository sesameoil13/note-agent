part of 'note_workspace.dart';

const _timeMarker = ' ⏰ ';
const _pendingMarker = '（待确认）';

/// One to-do line. The time text follows [_timeMarker] so that a time changed
/// in Obsidian can be read back; legacy notes omit it until rewritten.
String _actionLine(WorkspaceAction a, bool withTime) =>
    '- [${a.completed ? 'x' : ' '}] ${_actionMarkdown(a.text)}'
    '${withTime && a.timeExpression.isNotEmpty ? '$_timeMarker${_actionMarkdown(a.timeExpression)}' : ''}'
    '${a.decision == ActionDecision.pending ? _pendingMarker : ''}';

String _unescapeMarkdown(String value) =>
    value.replaceAllMapped(RegExp(r'\\([\\`*_\[\]<>#])'), (m) => m[1]!);

/// Reads edits made outside the App (Obsidian, or Sync delivering another
/// device's copy) to App-managed notes. Per ADR 0002 the later original device
/// modification time wins; equal times use a stable content tiebreak. To-do
/// completion is independent of that rule: a tick completes the lifecycle it
/// was made in, and an untick never revives a completed one.
extension _VaultEdits on NoteWorkspace {
  static const _anchor = '\n## 关联\n';

  Future<List<String>> _readVaultEdits() async {
    final changed = <String>[];
    for (final note in notes) {
      if (note.status != NoteStatus.localSaved ||
          // A restore still publishing its file finishes through its own
          // recovery; the missing file is not a rename or an edit.
          _disposalState(note.id) == 'restoring' ||
          _renamePlan(note.id) != null ||
          _hasActionChange(note.id) ||
          _hasAssociationChange(note.id) ||
          _hasOwnWriteInFlight(note.id)) {
        continue;
      }
      try {
        if (await _readNoteEdit(note)) changed.add(note.id);
      } on FileSystemException {
        /* Unavailable or concurrently changing; read again next time. */
      }
    }
    return changed;
  }

  /// An App write recorded but not yet acknowledged must finish through its
  /// own recovery; reading it here would echo it back as an external edit.
  bool _hasOwnWriteInFlight(String noteId) =>
      _database.select(
        'SELECT 1 FROM document_imports WHERE note_id=? AND vault=? AND write_plan IS NOT NULL',
        [noteId, vaultStorage.identity],
      ).isNotEmpty ||
      _database
          .select('SELECT payload FROM text_jobs WHERE note_id=? AND vault=?', [
            noteId,
            vaultStorage.identity,
          ])
          .any(
            (r) =>
                (jsonDecode(r['payload'] as String) as Map)['writePlan'] !=
                null,
          );

  Future<bool> _readNoteEdit(WorkspaceNote note) async {
    var path = vaultStorage.relativePath(note.notePath);
    var renamed = false;
    if (!await vaultStorage.exists(path)) {
      final found = await _findRenamedNote(note);
      if (found == null) return false;
      path = found;
      _database.execute(
        'UPDATE notes SET title=?,note_path=?,title_collision=0 WHERE id=? AND vault=?',
        [
          p.posix.basenameWithoutExtension(found.replaceAll('\\', '/')),
          vaultStorage.reference(found),
          note.id,
          vaultStorage.identity,
        ],
      );
      note = notes.firstWhere((n) => n.id == note.id);
      renamed = true;
    }
    return await _readNoteContent(note, path) || renamed;
  }

  /// Obsidian keeps the source link when renaming or moving a note (rewriting
  /// only its relative prefix), so the note id in it is a stable identity.
  Future<String?> _findRenamedNote(WorkspaceNote note) async {
    final owned = {
      for (final n in notes) vaultStorage.relativePath(n.notePath),
    };
    final marker = 'attachments/note-agent/${note.id}.txt';
    final candidates = <String>[];
    for (final candidate in await vaultStorage.listNotePaths()) {
      if (owned.contains(candidate)) continue;
      if ((await vaultStorage.readText(candidate)).contains(marker)) {
        candidates.add(candidate);
      }
    }
    // A duplicated copy is ambiguous; leave it for the user rather than guess.
    return candidates.length == 1 ? candidates.single : null;
  }

  Future<bool> _readNoteContent(WorkspaceNote note, String path) async {
    final text = await vaultStorage.readText(path);
    final position = text.indexOf(_anchor);
    if (position < 0 || position != text.lastIndexOf(_anchor)) return false;
    final head = text.substring(0, position);
    final expected = _markdown(note).split(_anchor).first;
    if (head == expected) return false;
    final mtime = await vaultStorage.modifiedTime(path) ?? _clock();
    final theirs = mtime.millisecondsSinceEpoch;
    final ours = note.modifiedAt.millisecondsSinceEpoch;
    final externalWins =
        theirs > ours || theirs == ours && head.compareTo(expected) > 0;
    final parsed = _parseHead(note, head);
    // Completion is independent of which content version wins.
    final ticked = parsed == null ? false : _applyTicks(note, parsed, mtime);
    if (!externalWins || parsed == null) {
      if (!externalWins) {
        // A late or tied-and-losing copy: restore the newer App version
        // without touching associations, sources or the time line below it.
        await vaultStorage.replaceText(
          path,
          text,
          expected + text.substring(position),
          'edit-${note.id}',
        );
        await _mirrorActionCompletion(note.id);
      }
      return ticked;
    }
    for (final action in parsed.actions) {
      final old = note.actions.where((a) => a.id == action.id).firstOrNull;
      if (old != null && old.timeExpression != action.timeExpression) {
        // A newer explicit time replaces one chosen while reopening.
        final key = '${note.id}:${action.id}';
        final state = _actionStateRow(key);
        if (state['completed'] != true && state.remove('time') != null) {
          _saveActionState(key, state);
        }
      }
    }
    final presentation = NotePresentation(
      kind: note.kind,
      actions: List.unmodifiable(parsed.actions),
      original: note.originalText,
      userDecided: note.presentation.userDecided,
      timeInNote: note.presentation.timeInNote,
    );
    final timeLine = RegExp(r'\n记录：([^\n]*) · 修改：[^\n]*\n$');
    final updated = text.replaceFirstMapped(
      timeLine,
      (m) => '\n记录：${m[1]} · 修改：${formatNoteTime(mtime)}\n',
    );
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'UPDATE notes SET body=?,modified_at=?,presentation=? WHERE id=? AND vault=?',
        [
          parsed.body,
          mtime.toIso8601String(),
          jsonEncode(presentation.toJson()),
          note.id,
          vaultStorage.identity,
        ],
      );
      _attachments.noteContentsChanged(note.id, updated);
      // A line deleted in Obsidian is a tombstone on every paired device, as
      // when the action is removed in the App.
      final kept = {for (final a in parsed.actions) a.id};
      for (final removed in note.actions.where((a) => !kept.contains(a.id))) {
        final key = '${note.id}:${removed.id}';
        final state = _actionStateRow(key)..['removed'] = true;
        final op = _todoOperation();
        _saveActionState(key, state);
        _enqueueTodo(note.id, removed.id, {
          'opId': op.opId,
          'kind': 'remove',
          'lifecycle': state['lifecycle'],
          'at': op.at,
        });
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    if (updated != text) {
      try {
        await vaultStorage.replaceText(path, text, updated, 'edit-${note.id}');
      } on FileSystemException {
        /* A newer edit arrived meanwhile; it is read on the next pass. */
      }
    }
    await _mirrorActionCompletion(note.id);
    return true;
  }

  /// A tick counts only where the App last wrote an unticked box, and only for
  /// the lifecycle in which it was made (a late copy cannot close a reopen).
  bool _applyTicks(WorkspaceNote note, _ParsedHead parsed, DateTime mtime) {
    var changed = false;
    for (final action in parsed.actions.where((a) => a.completed)) {
      final old = note.actions.where((a) => a.id == action.id).firstOrNull;
      if (old == null || old.completed || !old.actionConfirmed) continue;
      final key = '${note.id}:${action.id}';
      final state = _actionStateRow(key);
      final started = state['startedAt'] as String?;
      if (state['completed'] == true ||
          state['removed'] == true ||
          started != null && mtime.isBefore(DateTime.parse(started))) {
        continue;
      }
      state['completed'] = true;
      state['completedAt'] = mtime.toIso8601String();
      for (final field in const [
        'time',
        'snoozeUntil',
        'snoozeStamp',
        'held',
        'silenced',
      ]) {
        state.remove(field);
      }
      // The tick syncs like an App completion, at the file's device time.
      final op = _todoOperation();
      _commitTodo(note.id, action.id, state, {
        'opId': op.opId,
        'kind': 'complete',
        'lifecycle': state['lifecycle'],
        'at': mtime.millisecondsSinceEpoch,
      });
      changed = true;
    }
    return changed;
  }

  _ParsedHead? _parseHead(WorkspaceNote note, String head) {
    if (note.kind == NoteKind.ordinary) {
      const prefix = '## 正文\n\n';
      if (!head.startsWith(prefix)) return null;
      final body = head.substring(prefix.length).trimRight();
      return body.trim().isEmpty ? null : _ParsedHead(body, const []);
    }
    const prefix = '## 待办\n\n', summary = '\n\n## 摘要\n\n';
    final split = head.indexOf(summary);
    if (!head.startsWith(prefix) || split < prefix.length) return null;
    final body = head
        .substring(split + summary.length)
        .trimRight()
        .split('\n')
        .map(_unescapeMarkdown)
        .join('\n');
    if (body.trim().isEmpty) return null;
    final lines = <({bool checked, String text, String time, bool pending})>[];
    final linePattern = RegExp(r'^- \[([ xX])\] (.*)$');
    for (final line in head.substring(prefix.length, split).split('\n')) {
      if (line.trim().isEmpty) continue;
      final m = linePattern.firstMatch(line.trimRight());
      if (m == null) return null;
      var rest = m[2]!;
      final pending = rest.endsWith(_pendingMarker);
      if (pending) {
        rest = rest.substring(0, rest.length - _pendingMarker.length);
      }
      var time = '';
      final marker = note.presentation.timeInNote
          ? rest.lastIndexOf(_timeMarker)
          : -1;
      if (marker >= 0) {
        time = _unescapeMarkdown(
          rest.substring(marker + _timeMarker.length).trim(),
        );
        rest = rest.substring(0, marker);
      }
      lines.add((
        checked: m[1] != ' ',
        text: _unescapeMarkdown(rest).trim(),
        time: time,
        pending: pending,
      ));
    }
    if (lines.isEmpty || lines.length > 20) return null;
    for (final line in lines) {
      if (line.text.isEmpty ||
          line.text.length > 500 ||
          line.time.length > 200 ||
          RegExp(r'[\x00-\x1f]').hasMatch(line.text + line.time)) {
        return null;
      }
    }
    // Keep stable identities: same text first, then same position (an edit),
    // otherwise a line added in Obsidian becomes a new confirmed to-do.
    final used = <String>{};
    final matched = List<WorkspaceAction?>.filled(lines.length, null);
    for (var i = 0; i < lines.length; i++) {
      final same = note.actions
          .where((a) => !used.contains(a.id) && a.text == lines[i].text)
          .firstOrNull;
      if (same != null) {
        matched[i] = same;
        used.add(same.id);
      }
    }
    for (var i = 0; i < lines.length; i++) {
      if (matched[i] == null &&
          i < note.actions.length &&
          !used.contains(note.actions[i].id) &&
          !lines.any((l) => l.text == note.actions[i].text)) {
        matched[i] = note.actions[i];
        used.add(note.actions[i].id);
      }
    }
    final actions = <WorkspaceAction>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i], old = matched[i];
      final time = note.presentation.timeInNote
          ? line.time
          : old?.timeExpression ?? '';
      actions.add(
        WorkspaceAction(
          id: old?.id ?? _createId(),
          text: line.text,
          decision: old?.decision ?? ActionDecision.confirmed,
          reason: old?.reason ?? 'none',
          timeExpression: time,
          timeStatus: old != null && old.timeExpression == time
              ? old.timeStatus
              : time.isEmpty
              ? ActionTimeStatus.absent
              : ActionTimeStatus.explicit,
          completed: line.checked,
        ),
      );
    }
    return _ParsedHead(body, actions);
  }
}

class _ParsedHead {
  const _ParsedHead(this.body, this.actions);
  final String body;
  final List<WorkspaceAction> actions;
}
