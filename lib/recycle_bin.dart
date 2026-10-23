part of 'note_workspace.dart';

/// Rows of `notes` that are in the 回收站 are invisible to every other feature.
const _notDeleted =
    "id NOT IN (SELECT note_id FROM note_disposals WHERE vault = notes.vault AND state = 'deleted')";

/// A note in the 回收站. Its retained copy stays until 永久清除 (not
/// automatic); its own source text and attachments remain in the vault.
class RecycledNote {
  const RecycledNote({
    required this.noteId,
    required this.title,
    required this.deletedAt,
    required this.markdown,
  });
  final String noteId, title;
  final DateTime deletedAt;

  /// The note file as it was when deleted, including edits made elsewhere.
  final String? markdown;
}

/// A restored reminder whose time passed while the note was in the 回收站.
/// It stays silent until the user reschedules or dismisses it in the App.
class ReminderDecision {
  const ReminderDecision({
    required this.noteId,
    required this.actionId,
    required this.text,
    required this.missedTime,
  });
  final String noteId, actionId, text;
  final DateTime missedTime;
}

extension _WorkspaceRecycleBin on NoteWorkspace {
  String? _disposalState(String noteId) =>
      _database.select(
            'SELECT state FROM note_disposals WHERE vault=? AND note_id=?',
            [vaultStorage.identity, noteId],
          ).firstOrNull?['state']
          as String?;

  Future<void> _archive(String noteId, bool archived) async {
    notes.firstWhere((n) => n.id == noteId);
    if (archived) {
      _database.execute(
        'INSERT OR REPLACE INTO note_disposals(vault,note_id,state,payload) VALUES (?,?,?,?)',
        [
          vaultStorage.identity,
          noteId,
          'archived',
          jsonEncode({'archivedAt': _clock().toIso8601String()}),
        ],
      );
    } else {
      _database.execute(
        "DELETE FROM note_disposals WHERE vault=? AND note_id=? AND state='archived'",
        [vaultStorage.identity, noteId],
      );
    }
  }

  Map<String, dynamic>? _disposal(String noteId) {
    final row = _database.select(
      'SELECT payload FROM note_disposals WHERE vault=? AND note_id=?',
      [vaultStorage.identity, noteId],
    ).firstOrNull;
    return row == null
        ? null
        : jsonDecode(row['payload'] as String) as Map<String, dynamic>;
  }

  void _saveDisposal(String noteId, String state, Map<String, dynamic> v) =>
      _database.execute(
        'INSERT OR REPLACE INTO note_disposals(vault,note_id,state,payload) VALUES (?,?,?,?)',
        [vaultStorage.identity, noteId, state, jsonEncode(v)],
      );

  List<RecycledNote> _recycleBin() => List.unmodifiable(
    _database
        .select(
          "SELECT note_id,payload FROM note_disposals WHERE vault=? AND state='deleted'",
          [vaultStorage.identity],
        )
        .map((row) {
          final v = jsonDecode(row['payload'] as String) as Map;
          return RecycledNote(
            noteId: row['note_id'] as String,
            title: v['title'] as String,
            deletedAt: DateTime.parse(v['deletedAt'] as String),
            markdown: v['markdown'] as String?,
          );
        })
        .toList()
      ..sort((a, b) => b.deletedAt.compareTo(a.deletedAt)),
  );

  Future<void> _delete(String noteId) async {
    final note = notes.firstWhere((n) => n.id == noteId);
    if (_renamePlan(noteId) != null ||
        _hasActionChange(noteId) ||
        _hasAssociationChange(noteId)) {
      throw StateError('笔记仍有未写入的修改，请先重试保存，再删除。');
    }
    if (_activeDocuments.containsKey(noteId) ||
        _retryingDocuments.contains(noteId) ||
        _processingText.containsKey(noteId) ||
        _preparingText.containsKey(noteId) ||
        textJobs.any(
          (j) =>
              j.noteId == noteId &&
              const [
                TextProcessingStatus.queued,
                TextProcessingStatus.prepared,
                TextProcessingStatus.sending,
                TextProcessingStatus.costPending,
              ].contains(j.status),
        )) {
      throw StateError('笔记仍在处理中，请等待或取消处理后再删除。');
    }
    final path = vaultStorage.relativePath(note.notePath);
    final markdown = await vaultStorage.exists(path)
        ? await vaultStorage.readText(path)
        : null;
    _database.execute('BEGIN IMMEDIATE');
    try {
      _saveDisposal(noteId, 'deleted', {
        'phase': 'deleting',
        'deletedAt': _clock().toIso8601String(),
        'title': note.title,
        'notePath': path,
        'markdown': markdown,
        'archived': note.archived,
      });
      // Plans are kept, marked as recycled, so restore can revive them as-is.
      for (final row in _database.select(
        'SELECT payload FROM reminder_plans WHERE vault=? AND removed=0',
        [vaultStorage.identity],
      )) {
        final v = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        if (v['noteId'] != noteId) continue;
        v['cancel'] = [...?v['cancel'] as List?, v['id']];
        v['recycled'] = true;
        _saveReminder(v, removed: true);
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    await _finishDelete(noteId);
  }

  /// Removes only the note file. Its source text, attachments and any file
  /// shared with other notes stay in the vault until 永久清除.
  Future<void> _finishDelete(String noteId) async {
    final v = _disposal(noteId)!;
    final path = v['notePath'] as String;
    try {
      if (await vaultStorage.exists(path)) {
        final current = await vaultStorage.readText(path);
        if (current != v['markdown']) {
          // Edited elsewhere since the copy was taken: keep the newest text.
          v['markdown'] = current;
          _saveDisposal(noteId, 'deleted', v);
        }
        await vaultStorage.deleteText(path, current);
      }
      v['phase'] = 'deleted';
      v.remove('error');
    } on FileSystemException catch (error) {
      v['error'] = error.message;
    }
    _saveDisposal(noteId, 'deleted', v);
  }

  Future<void> _recoverDisposals() async {
    for (final row in _database.select(
      "SELECT note_id,payload FROM note_disposals WHERE vault=? AND state='deleted'",
      [vaultStorage.identity],
    )) {
      final v = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      if (v['phase'] == 'deleting') {
        await _finishDelete(row['note_id'] as String);
      }
    }
    for (final row in _database.select(
      "SELECT note_id FROM note_disposals WHERE vault=? AND state='restoring'",
      [vaultStorage.identity],
    )) {
      await _finishRestore(row['note_id'] as String);
    }
  }

  Future<WorkspaceNote> _restore(String noteId) async {
    var v = _disposal(noteId);
    if (v == null || _disposalState(noteId) == 'archived') {
      throw StateError('回收站中没有这条记录。');
    }
    if (_disposalState(noteId) == 'deleted') {
      if (v['phase'] == 'deleting') {
        await _finishDelete(noteId);
        v = _disposal(noteId)!;
        if (v['phase'] == 'deleting') {
          throw StateError('删除尚未完成：${v['error']}');
        }
      }
      final now = _clock();
      _database.execute('BEGIN IMMEDIATE');
      try {
        v['phase'] = 'restoring';
        _saveDisposal(noteId, 'restoring', v);
        for (final row in _database.select(
          'SELECT payload FROM reminder_plans WHERE vault=? AND removed=1',
          [vaultStorage.identity],
        )) {
          final plan =
              jsonDecode(row['payload'] as String) as Map<String, dynamic>;
          if (plan['noteId'] != noteId || plan.remove('recycled') != true) {
            continue;
          }
          final time = DateTime.parse(plan['time'] as String);
          if (time.isAfter(now)) {
            // Same plan and time, new notification id: the cancelled one
            // must never be confused with the revived reminder.
            final oldId = plan['id'] as String;
            plan['revision'] = (plan['revision'] as int) + 1;
            plan['id'] =
                '${oldId.substring(0, oldId.lastIndexOf(':'))}:${plan['revision']}';
            plan['status'] = ReminderStatus.pending.name;
            plan['immediate'] = false;
            _saveReminder(plan);
          } else {
            _saveReminder(plan, removed: true);
            final key = plan['key'] as String;
            final state = _actionStateRow(key);
            state['held'] = time.toIso8601String();
            _saveActionState(key, state);
          }
        }
        _database.execute('COMMIT');
      } catch (_) {
        _database.execute('ROLLBACK');
        rethrow;
      }
    }
    return _finishRestore(noteId);
  }

  /// Publishes the retained copy under a title no other note or file uses.
  Future<WorkspaceNote> _finishRestore(String noteId) async {
    final v = _disposal(noteId)!;
    var note = notes.firstWhere((n) => n.id == noteId);
    final text = v['markdown'] as String? ?? _markdown(note);
    var path = v['restorePath'] as String?;
    if (path == null ||
        await vaultStorage.exists(path) &&
            await vaultStorage.readText(path) != text) {
      final naming = await _chooseTitle(
        v['title'] as String,
        const [],
        excludingId: noteId,
        ownsCurrentFile: false,
      );
      path = '${naming.title}.md';
      v['restorePath'] = path;
      _database.execute('BEGIN IMMEDIATE');
      try {
        _saveDisposal(noteId, 'restoring', v);
        _database.execute(
          'UPDATE notes SET title=?, note_path=?, title_collision=? WHERE id=?',
          [
            naming.title,
            vaultStorage.reference(path),
            naming.collision ? 1 : 0,
            noteId,
          ],
        );
        _database.execute('COMMIT');
      } catch (_) {
        _database.execute('ROLLBACK');
        rethrow;
      }
    }
    try {
      await vaultStorage.publishText(path, text, 'restore-$noteId');
    } on FileSystemException catch (error) {
      v['error'] = error.message;
      _saveDisposal(noteId, 'restoring', v);
      _database.execute('UPDATE notes SET status=?, error=? WHERE id=?', [
        NoteStatus.exportFailed.name,
        error.message,
        noteId,
      ]);
      return notes.firstWhere((n) => n.id == noteId);
    }
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'DELETE FROM note_disposals WHERE vault=? AND note_id=?',
        [vaultStorage.identity, noteId],
      );
      _database.execute('UPDATE notes SET status=?, error=NULL WHERE id=?', [
        NoteStatus.localSaved.name,
        noteId,
      ]);
      _attachments.noteContentsChanged(noteId, text);
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    note = notes.firstWhere((n) => n.id == noteId);
    return note;
  }

  List<ReminderDecision> _reminderDecisions() => List.unmodifiable([
    for (final note in notes)
      for (final action in note.actions.where((a) => a.actionConfirmed))
        if (_actionStateRow('${note.id}:${action.id}')['held']
            case final String held)
          ReminderDecision(
            noteId: note.id,
            actionId: action.id,
            text: action.text,
            missedTime: DateTime.parse(held),
          ),
  ]);

  Future<void> _decideReminder(
    String noteId,
    String actionId,
    DateTime? time,
  ) async {
    _confirmedAction(noteId, actionId);
    final key = '$noteId:$actionId';
    final state = _actionStateRow(key);
    if (state.remove('held') == null) throw StateError('该提醒无需决定。');
    if (time == null) {
      state['silenced'] = true;
    } else {
      state['time'] = time.toIso8601String();
    }
    _saveActionState(key, state);
  }
}
