part of 'note_workspace.dart';

/// Rows of `notes` that are in the 回收站 are invisible to every other feature.
const _notDeleted =
    "id NOT IN (SELECT note_id FROM note_disposals WHERE vault = notes.vault AND state IN ('deleted','purged'))";

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

  Future<void> _delete(String noteId, {bool remote = false}) async {
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
      if (!remote) _recordNoteMark(noteId, 'trash');
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
      "SELECT note_id FROM note_disposals WHERE vault=? AND state='purged'",
      [vaultStorage.identity],
    )) {
      await _finishPurge(row['note_id'] as String);
    }
    for (final row in _database.select(
      "SELECT note_id FROM note_disposals WHERE vault=? AND state='restoring'",
      [vaultStorage.identity],
    )) {
      await _finishRestore(row['note_id'] as String);
    }
  }

  Future<WorkspaceNote> _restore(String noteId, {bool remote = false}) async {
    var v = _disposal(noteId);
    if (v == null ||
        _disposalState(noteId) == 'archived' ||
        _disposalState(noteId) == 'purged') {
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
      // The same note may already be back at its old path (restored on a
      // paired device and delivered by Obsidian Sync): adopt it, never copy.
      final oldPath = v['notePath'] as String;
      if (v['restorePath'] == null &&
          await vaultStorage.exists(oldPath) &&
          await vaultStorage.readText(oldPath) == v['markdown']) {
        v['restorePath'] = oldPath;
      }
      final now = _clock();
      _database.execute('BEGIN IMMEDIATE');
      try {
        if (!remote) _recordNoteMark(noteId, 'restore');
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

/// The reserved action id under which deletion marks travel through the
/// to-do sync endpoint (same as the Worker's NOTE_MARK).
const _noteMarkId = '_note';
const _noteMarkNames = {
  'trash': 'trashed',
  'restore': 'restored',
  'purge': 'purged',
};

/// The Worker's joinMark: a purge is final; otherwise the later device time
/// (operation id as tiebreak) wins between deletion and restore.
Map<String, dynamic> _joinNoteMark(
  Map<String, dynamic>? a,
  Map<String, dynamic> b,
) {
  if (a == null) return b;
  String stamp(Map m) => m['markStamp'] as String? ?? '';
  final purged = [a, b].where((m) => m['mark'] == 'purged').toList();
  if (purged.isNotEmpty) {
    return purged.reduce((x, y) => stamp(y).compareTo(stamp(x)) > 0 ? y : x);
  }
  return stamp(b).compareTo(stamp(a)) > 0 ? b : a;
}

extension _WorkspacePurge on NoteWorkspace {
  Map<String, dynamic>? _noteMark(String noteId) {
    final row = _database.select(
      'SELECT payload FROM note_marks WHERE vault=? AND note_id=?',
      [vaultStorage.identity, noteId],
    ).firstOrNull;
    return row == null
        ? null
        : jsonDecode(row['payload'] as String) as Map<String, dynamic>;
  }

  /// Joins a mark (local or pulled) into the local view; returns true when it
  /// changed anything.
  bool _mergeNoteMark(String noteId, Map<String, dynamic> incoming) {
    final before = _noteMark(noteId);
    final next = _joinNoteMark(before, {
      'mark': incoming['mark'],
      'markStamp': incoming['markStamp'],
    });
    if (before != null && jsonEncode(before) == jsonEncode(next)) return false;
    _database.execute(
      'INSERT OR REPLACE INTO note_marks(vault,note_id,payload) VALUES (?,?,?)',
      [vaultStorage.identity, noteId, jsonEncode(next)],
    );
    return true;
  }

  /// Records a local trash/restore/purge and queues it for paired devices.
  /// Called inside the transaction that commits the local change.
  void _recordNoteMark(String noteId, String kind) {
    final op = _todoOperation();
    // A local decision always follows the one it reverses, even when the
    // device clock has not moved (or moved back) since.
    final previous = _noteMark(noteId)?['markStamp'] as String?;
    final after = previous == null
        ? -1
        : int.parse(previous.substring(0, previous.indexOf(':')));
    final at = max(op.at, after + 1);
    _mergeNoteMark(noteId, {
      'mark': _noteMarkNames[kind],
      'markStamp': _todoStamp(at, op.opId),
    });
    _enqueueTodo(noteId, _noteMarkId, {
      'opId': op.opId,
      'kind': kind,
      'lifecycle': 1,
      'at': at,
    });
  }

  /// Notes whose state another device decided: in the 回收站, purged, or
  /// marked so. Their to-do states never count as "awaiting the note".
  Set<String> _disposedNoteIds() => {
    for (final row in _database.select(
      "SELECT note_id FROM note_disposals WHERE vault=? AND state<>'archived'",
      [vaultStorage.identity],
    ))
      row['note_id'] as String,
    for (final row in _database.select(
      'SELECT note_id,payload FROM note_marks WHERE vault=?',
      [vaultStorage.identity],
    ))
      if ((jsonDecode(row['payload'] as String) as Map)['mark'] != 'restored')
        row['note_id'] as String,
  };

  /// Brings local notes in line with the joined deletion marks. A note that
  /// cannot change yet (unsaved edits, processing, a restore in progress)
  /// keeps its mark and is retried on the next sync or start.
  Future<void> _applyNoteMarks() async {
    for (final row in _database.select(
      'SELECT note_id,payload FROM note_marks WHERE vault=?',
      [vaultStorage.identity],
    )) {
      final id = row['note_id'] as String;
      final mark = (jsonDecode(row['payload'] as String) as Map)['mark'];
      if (_database.select('SELECT id FROM notes WHERE id=? AND vault=?', [
        id,
        vaultStorage.identity,
      ]).isEmpty) {
        continue; // The note has not arrived here (yet).
      }
      final state = _disposalState(id);
      try {
        switch (mark) {
          case 'trashed' when state == null || state == 'archived':
            await _delete(id, remote: true);
          case 'restored' when state == 'deleted':
            await _restore(id, remote: true);
          case 'purged' when state != 'purged' && state != 'restoring':
            if (state != 'deleted') await _delete(id, remote: true);
            await _purge(id, remote: true);
        }
      } on StateError {
        // Retried later; the mark itself is already durable.
      } on FileSystemException {
        // Retried later.
      }
    }
  }

  Future<List<WorkspaceNote>> _restoreMany(List<String> ids) async {
    final restored = <WorkspaceNote>[];
    final failed = <String>[];
    for (final id in ids) {
      try {
        restored.add(await _restore(id));
      } on StateError catch (error) {
        failed.add('${_disposal(id)?['title'] ?? id}：${error.message}');
      }
    }
    if (failed.isNotEmpty) {
      throw StateError('部分内容未恢复：${failed.join('；')}');
    }
    return List.unmodifiable(restored);
  }

  Future<void> _purgeMany(List<String> ids) async {
    if (ids.any((id) => _disposalState(id) != 'deleted')) {
      throw StateError('只有回收站中的内容可以永久清除。');
    }
    for (final id in ids) {
      await _purge(id);
    }
  }

  /// 永久清除: drops the retained copy and every local record that could bring
  /// the note back, then removes its own source files nobody else uses.
  Future<void> _purge(String noteId, {bool remote = false}) async {
    if (_disposalState(noteId) != 'deleted') {
      throw StateError('只有回收站中的内容可以永久清除。');
    }
    var v = _disposal(noteId)!;
    if (v['phase'] == 'deleting') {
      await _finishDelete(noteId);
      v = _disposal(noteId)!;
      if (v['phase'] == 'deleting') {
        throw StateError('删除尚未完成，暂不能永久清除：${v['error']}');
      }
    }
    final files = _ownedFiles(noteId, v['markdown'] as String?);
    _database.execute('BEGIN IMMEDIATE');
    try {
      _saveDisposal(noteId, 'purged', {
        'phase': 'purging',
        'purgedAt': _clock().toIso8601String(),
        'vaultFiles': files.vault,
        'localFiles': files.local,
      });
      final vault = vaultStorage.identity;
      _database.execute(
        "UPDATE notes SET title='', body='', presentation=NULL, naming_request=NULL WHERE id=? AND vault=?",
        [noteId, vault],
      );
      _database.execute(
        'DELETE FROM action_states WHERE vault=? AND substr(action_key,1,?)=?',
        [vault, noteId.length + 1, '$noteId:'],
      );
      for (final table in [
        'attachments',
        'note_associations',
        'source_corrections',
      ]) {
        _database.execute('DELETE FROM $table WHERE vault=? AND note_id=?', [
          vault,
          noteId,
        ]);
      }
      _database.execute(
        'UPDATE document_imports SET result=NULL, write_plan=NULL WHERE vault=? AND note_id=?',
        [vault, noteId],
      );
      // Cost records stay for the budget; the text they carried does not.
      for (final row in _database.select(
        'SELECT id,payload FROM text_jobs WHERE vault=? AND note_id=?',
        [vault, noteId],
      )) {
        final job = jsonDecode(row['payload'] as String) as Map;
        for (final key in const [
          'original',
          'baseText',
          'result',
          'noteSnapshot',
          'reply',
          'writePlan',
        ]) {
          job.remove(key);
        }
        _database.execute('UPDATE text_jobs SET payload=? WHERE id=?', [
          jsonEncode(job),
          row['id'],
        ]);
      }
      if (!remote) _recordNoteMark(noteId, 'purge');
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    await _finishPurge(noteId);
  }

  /// Files the App created for this note: its source text, attachment copies
  /// and anything under the App's attachment folder its last copy links to.
  /// Files outside that folder belong to the user and are never purged.
  ({List<String> vault, List<String> local}) _ownedFiles(
    String noteId,
    String? markdown,
  ) {
    const folder = 'attachments/note-agent/';
    final vault = <String>{};
    final local = <String>{};
    final source = _database.select(
      'SELECT source_path FROM notes WHERE id=? AND vault=?',
      [noteId, vaultStorage.identity],
    ).firstOrNull?['source_path'];
    if (source is String && source.isNotEmpty) {
      vault.add(vaultStorage.relativePath(source));
    }
    for (final a in _attachments.attachments.where((a) => a.noteId == noteId)) {
      vault.add(vaultStorage.relativePath(a.sourcePath));
      if (a.copyPath != null) vault.add(vaultStorage.relativePath(a.copyPath!));
      local.add(a.originalPath);
    }
    for (final m in RegExp(
      r'attachments/note-agent/[^\s)\]|#]+',
    ).allMatches(markdown ?? '')) {
      try {
        vault.add(Uri.decodeFull(m[0]!));
      } on ArgumentError {
        vault.add(m[0]!);
      }
    }
    return (
      vault: vault.where((v) => v.startsWith(folder)).toList()..sort(),
      local: local.toList()..sort(),
    );
  }

  Future<void> _finishPurge(String noteId) async {
    final v = _disposal(noteId)!;
    if (v['phase'] != 'purging') return;
    final referenced = await _referencedElsewhere(noteId);
    try {
      for (final path in (v['vaultFiles'] as List).cast<String>()) {
        if (referenced(path)) continue;
        final storage = vaultStorage;
        if (storage is BinaryVaultStorage) {
          await (storage as BinaryVaultStorage).deleteFile(path);
        } else if (await storage.exists(path)) {
          await storage.deleteText(path, await storage.readText(path));
        }
      }
      final stillUsed = {
        for (final a in _attachments.attachments) a.originalPath,
      };
      for (final path in (v['localFiles'] as List).cast<String>()) {
        if (stillUsed.contains(path)) continue;
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } on FileSystemException catch (error) {
      v['error'] = error.message;
      _saveDisposal(noteId, 'purged', v);
      return;
    }
    _saveDisposal(noteId, 'purged', {
      'phase': 'purged',
      'purgedAt': v['purgedAt'],
    });
  }

  /// Whether another note (in the vault, or still in the 回收站) or another
  /// App record still uses a file.
  Future<bool Function(String)> _referencedElsewhere(String noteId) async {
    final texts = <String>[];
    for (final path in await vaultStorage.listNotePaths()) {
      try {
        texts.add(await vaultStorage.readText(path));
      } on FileSystemException {
        // Unreadable notes are treated as not referencing anything.
      }
    }
    for (final row in _database.select(
      "SELECT note_id,payload FROM note_disposals WHERE vault=? AND state IN ('deleted','restoring') AND note_id<>?",
      [vaultStorage.identity, noteId],
    )) {
      final markdown =
          (jsonDecode(row['payload'] as String) as Map)['markdown'];
      if (markdown is String) texts.add(markdown);
    }
    final owned = <String>{
      for (final row in _database.select(
        "SELECT source_path FROM notes WHERE vault=? AND id<>? AND source_path<>''",
        [vaultStorage.identity, noteId],
      ))
        vaultStorage.relativePath(row['source_path'] as String),
      for (final a in _attachments.attachments.where(
        (a) => a.noteId != noteId,
      )) ...[
        vaultStorage.relativePath(a.sourcePath),
        if (a.copyPath != null) vaultStorage.relativePath(a.copyPath!),
      ],
    };
    return (path) {
      if (owned.contains(path)) return true;
      final forms = {
        path,
        Uri(path: path).toString(),
        Uri.encodeFull(path),
        '[[${p.basename(path)}',
      };
      return texts.any((t) => forms.any((f) => t.contains(f)));
    };
  }
}
