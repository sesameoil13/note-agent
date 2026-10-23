part of 'note_workspace.dart';

/// Where to-do lifecycle coordination with paired devices stands. This is
/// independent of note-file Sync: a coordinated state never means the note
/// body has arrived (ADR 0001).
class WorkspaceTodoSync {
  const WorkspaceTodoSync({
    required this.status,
    required this.message,
    this.pendingOperations = 0,
    this.lastSyncedAt,
    this.awaitingNote = const [],
  });
  final TaskStatusSync status;
  final String message;

  /// Local lifecycle operations not yet accepted by the status endpoint.
  final int pendingOperations;
  final DateTime? lastSyncedAt;

  /// States received from another device whose note body is not here yet.
  final List<TodoAwaitingNote> awaitingNote;
}

/// A to-do state that arrived before its note (or its updated action list).
class TodoAwaitingNote {
  const TodoAwaitingNote({
    required this.noteId,
    required this.actionId,
    required this.lifecycle,
    required this.completed,
  });
  final String noteId, actionId;
  final int lifecycle;
  final bool completed;
}

/// Stable ordering for "later device time wins" (ADR 0002); the operation id
/// breaks ties. Identical to the Worker's stamp.
String _todoStamp(int at, String opId) =>
    '${at.toString().padLeft(16, '0')}:$opId';

/// The same commutative, idempotent join the Worker applies: a higher
/// lifecycle wins, completion wins within a lifecycle, later stamps win between
/// snoozes or reopen times, and removal is a tombstone. Joining an older or
/// duplicated state never moves a newer one backwards.
Map<String, dynamic> _joinTodo(Map<String, dynamic> a, Map<String, dynamic> b) {
  final la = a['lifecycle'] as int, lb = b['lifecycle'] as int;
  Map<String, dynamic> r;
  if (la != lb) {
    r = la > lb ? a : b;
  } else {
    String stamp(Map m, String f) => (m['${f}Stamp'] as String?) ?? '';
    final s = stamp(b, 'snooze').compareTo(stamp(a, 'snooze')) > 0 ? b : a;
    final o = stamp(b, 'reopen').compareTo(stamp(a, 'reopen')) > 0 ? b : a;
    final done = [a, b]
        .where((x) => x['completed'] == true && x['completedAt'] != null)
        .map((x) => x['completedAt'] as int);
    r = {
      'lifecycle': la,
      'completed': a['completed'] == true || b['completed'] == true,
      'completedAt': done.isEmpty ? null : done.reduce(min),
      'snoozeUntil': s['snoozeUntil'],
      'snoozeStamp': s['snoozeStamp'],
      'reopenTime': o['reopenTime'],
      'reopenStamp': o['reopenStamp'],
    };
  }
  return _normalizeTodo({
    ...r,
    'removed': a['removed'] == true || b['removed'] == true,
  });
}

Map<String, dynamic> _normalizeTodo(Map<String, dynamic> s) {
  final completed = s['completed'] == true;
  return {
    'lifecycle': s['lifecycle'],
    'completed': completed,
    'completedAt': completed ? s['completedAt'] : null,
    'removed': s['removed'] == true,
    // Completion closes the lifecycle, so its snooze no longer applies.
    'snoozeUntil': completed ? null : s['snoozeUntil'],
    'snoozeStamp': completed ? null : s['snoozeStamp'],
    'reopenTime': s['reopenTime'],
    'reopenStamp': s['reopenStamp'],
  };
}

extension _WorkspaceTodoSync on NoteWorkspace {
  /// The synced view of a local `action_states` row.
  Map<String, dynamic> _todoShape(Map<String, dynamic> local) =>
      _normalizeTodo({
        'lifecycle': local['lifecycle'],
        'completed': local['completed'] == true,
        'completedAt': local['completedAt'] == null
            ? null
            : DateTime.parse(local['completedAt']).millisecondsSinceEpoch,
        'removed': local['removed'] == true,
        'snoozeUntil': local['snoozeUntil'],
        'snoozeStamp': local['snoozeStamp'],
        'reopenTime': local['reopenTime'],
        'reopenStamp': local['reopenStamp'],
      });

  Map<String, dynamic> _fromTodoShape(
    Map<String, dynamic> s,
    Map<String, dynamic> local,
  ) {
    final completed = s['completed'] == true;
    final next = <String, dynamic>{
      'lifecycle': s['lifecycle'],
      'completed': completed,
      if (s['removed'] == true) 'removed': true,
      if (s['snoozeStamp'] != null) ...{
        'snoozeUntil': s['snoozeUntil'],
        'snoozeStamp': s['snoozeStamp'],
      },
      if (s['reopenStamp'] != null) ...{
        'reopenTime': s['reopenTime'],
        'reopenStamp': s['reopenStamp'],
      },
    };
    if (s['lifecycle'] == local['lifecycle'] && local['startedAt'] != null) {
      next['startedAt'] = local['startedAt'];
    } else if (s['reopenStamp'] case final String stamp) {
      // A tick read from a copy older than the reopen elsewhere must not
      // close the new lifecycle.
      next['startedAt'] = DateTime.fromMillisecondsSinceEpoch(
        int.parse(stamp.substring(0, stamp.indexOf(':'))),
      ).toIso8601String();
    }
    if (completed) {
      final at = s['completedAt'] as int?;
      final same =
          local['completedAt'] != null &&
          DateTime.parse(local['completedAt']).millisecondsSinceEpoch == at;
      next['completedAt'] = same
          ? local['completedAt']
          : (at == null ? _clock() : DateTime.fromMillisecondsSinceEpoch(at))
                .toIso8601String();
    } else if (s['lifecycle'] == local['lifecycle'] &&
        s['reopenStamp'] == local['reopenStamp']) {
      // A later explicit reminder edit on this device removed the reopen time.
      if (local['time'] != null) next['time'] = local['time'];
      // A reminder missed in the 回收站 stays local until the user decides.
      if (local['held'] != null) next['held'] = local['held'];
      if (local['silenced'] == true) next['silenced'] = true;
    } else if (s['reopenTime'] != null) {
      next['time'] = DateTime.fromMillisecondsSinceEpoch(s['reopenTime'] as int)
          .toIso8601String();
    }
    return next;
  }

  /// Saves the local state and queues the operation in one transaction, so an
  /// accepted local action is never lost or sent without being applied here.
  void _commitTodo(
    String noteId,
    String actionId,
    Map<String, dynamic> state,
    Map<String, dynamic> op, {
    Map<String, dynamic>? plan,
  }) {
    _database.execute('BEGIN IMMEDIATE');
    try {
      _saveActionState('$noteId:$actionId', state);
      if (plan != null) _saveReminder(plan);
      _enqueueTodo(noteId, actionId, op);
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void _enqueueTodo(String noteId, String actionId, Map<String, dynamic> op) {
    _database.execute(
      'INSERT INTO todo_outbox(vault,op_id,payload) VALUES (?,?,?)',
      [
        vaultStorage.identity,
        op['opId'],
        jsonEncode({'noteId': noteId, 'actionId': actionId, ...op}),
      ],
    );
  }

  /// A fresh operation id and its device-time stamp.
  ({String opId, int at, String stamp}) _todoOperation() {
    final opId = NoteWorkspace._randomId();
    final at = _clock().millisecondsSinceEpoch;
    return (opId: opId, at: at, stamp: _todoStamp(at, opId));
  }

  Map<String, dynamic> _todoSyncRow() {
    final rows = _database.select(
      'SELECT payload FROM todo_sync WHERE vault=?',
      [vaultStorage.identity],
    );
    return rows.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
  }

  void _saveTodoSyncRow(Map<String, dynamic> row) => _database.execute(
    'INSERT OR REPLACE INTO todo_sync(vault,payload) VALUES (?,?)',
    [vaultStorage.identity, jsonEncode(row)],
  );

  int _pendingTodoOperations() =>
      _database.select('SELECT COUNT(*) AS n FROM todo_outbox WHERE vault=?', [
            vaultStorage.identity,
          ]).single['n']
          as int;

  WorkspaceTodoSync _todoSyncState() {
    final pending = _pendingTodoOperations();
    final row = _todoSyncRow();
    final last = row['lastSyncedAt'] as String?;
    final status = switch (row['status']) {
      'offline' => TaskStatusSync.offline,
      'synced' when pending > 0 => TaskStatusSync.pending,
      'synced' => TaskStatusSync.synced,
      _ => TaskStatusSync.notConnected,
    };
    return WorkspaceTodoSync(
      status: status,
      pendingOperations: pending,
      lastSyncedAt: last == null ? null : DateTime.parse(last),
      awaitingNote: _todosAwaitingNote(),
      message: switch (status) {
        TaskStatusSync.notConnected =>
          pending > 0 ? '尚未与其他设备协调；$pending 项待办操作保留在本机。' : '尚未与其他设备协调待办状态。',
        TaskStatusSync.pending => '$pending 项待办操作等待上传。',
        TaskStatusSync.offline => '暂时无法连接待办状态服务；$pending 项操作保留在本机，联网后自动协调。',
        TaskStatusSync.synced => '待办状态已与其他设备协调。',
      },
    );
  }

  List<TodoAwaitingNote> _todosAwaitingNote() {
    final byId = {for (final n in notes) n.id: n};
    final disposed = _disposedNoteIds();
    final result = <TodoAwaitingNote>[];
    for (final row in _database.select(
      'SELECT action_key,payload FROM action_states WHERE vault=? ORDER BY action_key',
      [vaultStorage.identity],
    )) {
      final key = row['action_key'] as String;
      final split = key.indexOf(':');
      final noteId = key.substring(0, split),
          actionId = key.substring(split + 1);
      final v = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      if (v['removed'] == true || disposed.contains(noteId)) continue;
      if (byId[noteId]?.actions.any((a) => a.id == actionId) ?? false) continue;
      result.add(
        TodoAwaitingNote(
          noteId: noteId,
          actionId: actionId,
          lifecycle: v['lifecycle'] as int,
          completed: v['completed'] == true,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// Push queued operations in order, then pull every state changed since the
  /// last cursor. Failures keep the queue for the next attempt; reminders are
  /// reconciled afterwards by the surrounding mutation.
  Future<TaskStatusSync> _syncTodos() async {
    final row = _todoSyncRow();
    var cursor = row['cursor'] as int? ?? 0;
    try {
      for (var round = 0; round < 100; round++) {
        final queued = _database.select(
          'SELECT op_id,payload FROM todo_outbox WHERE vault=? ORDER BY seq LIMIT 20',
          [vaultStorage.identity],
        );
        final result = await connection.requestTodoSync({
          'ops': [for (final q in queued) jsonDecode(q['payload'] as String)],
          'after': cursor,
        });
        final accepted = (result['accepted'] as List).cast<String>();
        final states = (result['states'] as List).cast<Map<String, dynamic>>();
        final changedNotes = <String>{};
        _database.execute('BEGIN IMMEDIATE');
        try {
          for (final id in accepted) {
            _database.execute(
              'DELETE FROM todo_outbox WHERE vault=? AND op_id=?',
              [vaultStorage.identity, id],
            );
          }
          for (final s in states) {
            final noteId = s['noteId'] as String;
            if (s['actionId'] == _noteMarkId) {
              _mergeNoteMark(noteId, s);
              continue;
            }
            final key = '$noteId:${s['actionId']}';
            final local = _actionStateRow(key);
            final before = _todoShape(local);
            final merged = _joinTodo(before, s);
            if (jsonEncode(merged) == jsonEncode(before)) continue;
            _saveActionState(key, _fromTodoShape(merged, local));
            if (merged['completed'] != before['completed']) {
              changedNotes.add(noteId);
            }
          }
          cursor = result['cursor'] as int;
          _saveTodoSyncRow({...row, 'cursor': cursor});
          _database.execute('COMMIT');
        } catch (_) {
          _database.execute('ROLLBACK');
          rethrow;
        }
        for (final noteId in changedNotes) {
          if (notes.any((n) => n.id == noteId && n.kind == NoteKind.todo)) {
            await _mirrorActionCompletion(noteId);
          }
        }
        if (queued.length < 20 && result['more'] != true) break;
      }
      await _applyNoteMarks();
      _saveTodoSyncRow({
        ..._todoSyncRow(),
        'status': 'synced',
        'lastSyncedAt': _clock().toIso8601String(),
      });
    } on ConnectionFailure {
      _saveTodoSyncRow({..._todoSyncRow(), 'status': 'offline'});
    }
    return _todoSyncState().status;
  }

  /// Applies a snooze chosen on another device to this device's plan for the
  /// same lifecycle. A locally chosen snooze carries the same stamp already.
  void _applySyncedSnooze(String key, Map<String, dynamic> state) {
    final until = state['snoozeUntil'] as int?;
    if (until == null) return;
    final rows = _database.select(
      'SELECT payload,removed FROM reminder_plans WHERE vault=? AND action_id=?',
      [vaultStorage.identity, key],
    );
    if (rows.isEmpty || rows.single['removed'] == 1) return;
    final v =
        jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    if (v['snoozeStamp'] == state['snoozeStamp'] ||
        (v['lifecycle'] as int? ?? 1) != state['lifecycle']) {
      return;
    }
    final oldId = v['id'] as String;
    final time = DateTime.fromMillisecondsSinceEpoch(until);
    v['revision'] = (v['revision'] as int) + 1;
    v['id'] = '${oldId.substring(0, oldId.lastIndexOf(':'))}:${v['revision']}';
    v['time'] = time.toIso8601String();
    v['status'] = ReminderStatus.pending.name;
    v['immediate'] = !time.isAfter(_clock());
    v['snoozed'] = true;
    v['snoozeStamp'] = state['snoozeStamp'];
    v['cancel'] = [...?v['cancel'] as List?, oldId];
    _saveReminder(v);
  }
}
