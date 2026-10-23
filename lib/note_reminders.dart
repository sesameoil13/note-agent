part of 'note_workspace.dart';

enum ReminderStatus { pending, scheduled, elapsed, blocked, failed }

class WorkspaceReminder {
  const WorkspaceReminder({
    required this.id,
    required this.noteId,
    required this.actionId,
    required this.text,
    required this.time,
    required this.explicitTime,
    required this.status,
    required this.immediate,
    required this.timeNeedsConfirmation,
    this.snoozed = false,
    this.lifecycle = 1,
    this.error,
  });
  final String id, noteId, actionId, text;
  final DateTime time;
  final bool explicitTime, immediate, timeNeedsConfirmation, snoozed;
  final int lifecycle;
  final ReminderStatus status;
  final String? error;
}

/// One to-do lifecycle. Completion wins within a lifecycle; only an explicit
/// reopen starts a new one, so stale notification actions cannot revive it.
class WorkspaceActionState {
  const WorkspaceActionState({
    required this.lifecycle,
    required this.completed,
    required this.notePending,
    this.completedAt,
    this.removed = false,
  });
  final int lifecycle;
  final bool completed;

  /// The action was removed (here or on a paired device); its reminders are
  /// cancelled and later operations cannot revive it.
  final bool removed;

  /// The note checkbox does not yet match; the local state is still durable.
  final bool notePending;
  final DateTime? completedAt;
}

extension _WorkspaceReminders on NoteWorkspace {
  ReminderDefaultsPreview _previewReminderDefaults() {
    final changes = <ReminderDefaultChange>[];
    final fingerprint = <String>[];
    final defaults = reminderDefaults;
    for (final row in _database.select(
      'SELECT payload FROM reminder_plans WHERE vault=? AND removed=0 ORDER BY action_id',
      [vaultStorage.identity],
    )) {
      final v = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      if (v['explicit'] == true || v['snoozed'] == true) continue;
      final note = notes.firstWhere((n) => n.id == v['noteId']);
      final action = note.actions.firstWhere((a) => a.id == v['actionId']);
      final next = _reminderTime(
        action,
        note.createdAt.toLocal(),
        defaults,
      ).time;
      if (next == DateTime.parse(v['time'])) continue;
      changes.add(
        ReminderDefaultChange._(
          v['key'],
          v['noteId'],
          v['actionId'],
          v['text'],
          DateTime.parse(v['time']),
          next,
        ),
      );
      fingerprint.add('${v['id']}:${v['time']}:${next.toIso8601String()}');
    }
    return ReminderDefaultsPreview._(
      List.unmodifiable(changes),
      jsonEncode([vaultStorage.identity, defaults.toJson(), fingerprint]),
    );
  }

  List<WorkspaceReminder> _reminderList() => List.unmodifiable(
    _database
        .select(
          'SELECT payload FROM reminder_plans WHERE vault=? AND removed=0 ORDER BY action_id',
          [vaultStorage.identity],
        )
        .map((r) {
          final v = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
          return WorkspaceReminder(
            id: v['id'],
            noteId: v['noteId'],
            actionId: v['actionId'],
            text: v['text'],
            time: DateTime.parse(v['time']),
            explicitTime: v['explicit'],
            status: ReminderStatus.values.byName(v['status']),
            immediate: v['immediate'],
            timeNeedsConfirmation: v['timeNeedsConfirmation'] == true,
            snoozed: v['snoozed'] == true,
            lifecycle: v['lifecycle'] as int? ?? 1,
            error: v['error'],
          );
        }),
  );

  void _saveReminder(Map<String, dynamic> v, {bool removed = false}) {
    _database.execute(
      'INSERT OR REPLACE INTO reminder_plans(vault,action_id,removed,payload) VALUES (?,?,?,?)',
      [vaultStorage.identity, v['key'], removed ? 1 : 0, jsonEncode(v)],
    );
  }

  Map<String, dynamic> _actionStateRow(String key) {
    final rows = _database.select(
      'SELECT payload FROM action_states WHERE vault=? AND action_key=?',
      [vaultStorage.identity, key],
    );
    return rows.isEmpty
        ? {'lifecycle': 1, 'completed': false}
        : jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
  }

  void _saveActionState(String key, Map<String, dynamic> state) =>
      _database.execute(
        'INSERT OR REPLACE INTO action_states(vault,action_key,payload) VALUES (?,?,?)',
        [vaultStorage.identity, key, jsonEncode(state)],
      );

  WorkspaceActionState _actionState(String noteId, String actionId) {
    final note = notes.firstWhere((n) => n.id == noteId);
    final action = note.actions.firstWhere((a) => a.id == actionId);
    final v = _actionStateRow(_actionKey(noteId, actionId));
    final completed = v['completed'] == true;
    return WorkspaceActionState(
      lifecycle: v['lifecycle'] as int,
      completed: completed,
      notePending: action.completed != completed,
      completedAt: completed ? DateTime.parse(v['completedAt']) : null,
      removed: v['removed'] == true,
    );
  }

  WorkspaceAction _confirmedAction(String noteId, String actionId) {
    final note = notes.where((n) => n.id == noteId).firstOrNull;
    final action = note?.actions.where((a) => a.id == actionId).firstOrNull;
    if (action == null) throw StateError('该行动已不存在。');
    if (!action.actionConfirmed) throw StateError('请先确认行动。');
    return action;
  }

  Future<void> _completeAction(
    String noteId,
    String actionId, {
    int? lifecycle,
  }) async {
    _confirmedAction(noteId, actionId);
    final key = _actionKey(noteId, actionId);
    final state = _actionStateRow(key);
    // A notification from an earlier lifecycle must not close a reopened item.
    if (lifecycle != null && lifecycle != state['lifecycle']) return;
    if (state['removed'] == true) throw StateError('该行动已删除。');
    if (state['completed'] != true) {
      final op = _todoOperation();
      state['completed'] = true;
      state['completedAt'] = DateTime.fromMillisecondsSinceEpoch(op.at)
          .toIso8601String();
      state.remove('time');
      state.remove('snoozeUntil');
      state.remove('held');
      state.remove('silenced');
      state.remove('snoozeStamp');
      _commitTodo(noteId, actionId, state, {
        'opId': op.opId,
        'kind': 'complete',
        'lifecycle': state['lifecycle'],
        'at': op.at,
      });
    }
    await _mirrorActionCompletion(noteId);
  }

  Future<void> _reopenAction(
    String noteId,
    String actionId,
    DateTime time,
  ) async {
    _confirmedAction(noteId, actionId);
    final key = _actionKey(noteId, actionId);
    final state = _actionStateRow(key);
    if (state['removed'] == true) throw StateError('该行动已删除。');
    if (state['completed'] != true) throw StateError('事项尚未完成，无需重新开启。');
    final op = _todoOperation();
    final lifecycle = (state['lifecycle'] as int) + 1;
    final reopenTime = time.millisecondsSinceEpoch;
    _commitTodo(
      noteId,
      actionId,
      {
        'lifecycle': lifecycle,
        'completed': false,
        'time': time.toIso8601String(),
        'reopenTime': reopenTime,
        'reopenStamp': op.stamp,
        // A tick read later from an older copy must not close this lifecycle.
        'startedAt': DateTime.fromMillisecondsSinceEpoch(op.at)
            .toIso8601String(),
      },
      {
        'opId': op.opId,
        'kind': 'reopen',
        'lifecycle': lifecycle,
        'at': op.at,
        'time': reopenTime,
      },
    );
    await _mirrorActionCompletion(noteId);
  }

  Future<void> _snoozeReminder(
    String noteId,
    String actionId, {
    int? minutes,
    String? notificationId,
    DateTime? armedUntil,
  }) async {
    final fromNotification = notificationId != null;
    _confirmedAction(noteId, actionId);
    final key = _actionKey(noteId, actionId);
    final rows = _database.select(
      'SELECT payload,removed FROM reminder_plans WHERE vault=? AND action_id=?',
      [vaultStorage.identity, key],
    );
    final state = _actionStateRow(key);
    if (state['completed'] == true || state['removed'] == true) {
      if (fromNotification) return;
      throw StateError('事项已完成，不再安排提醒。');
    }
    if (rows.isEmpty || rows.single['removed'] == 1) {
      if (fromNotification) return;
      throw StateError('该行动没有可延后的提醒。');
    }
    final v =
        jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    // Only the current notification may snooze; a duplicate or superseded
    // delivery must not replace a newer time chosen elsewhere.
    if (fromNotification && notificationId != v['id']) return;
    if (armedUntil != null) {
      // Android already re-armed this same alert natively while the App was
      // closed; adopting it avoids a second, later alarm.
      v['time'] = armedUntil.toIso8601String();
      v['status'] = ReminderStatus.pending.name;
      v['immediate'] = false;
      v['snoozed'] = true;
      _saveReminder(v);
      return;
    }
    final length = minutes ?? reminderDefaults.snoozeMinutes;
    if (length < 1 || length > 1440) throw ArgumentError('稍后提醒需在 1–1440 分钟之间。');
    final oldId = v['id'] as String;
    v['revision'] = (v['revision'] as int) + 1;
    v['id'] = '${oldId.substring(0, oldId.lastIndexOf(':'))}:${v['revision']}';
    v['time'] = _clock().add(Duration(minutes: length)).toIso8601String();
    v['status'] = ReminderStatus.pending.name;
    v['immediate'] = false;
    v['snoozed'] = true;
    v['cancel'] = [...?v['cancel'] as List?, oldId];
    final op = _todoOperation();
    final until = DateTime.parse(v['time']).millisecondsSinceEpoch;
    v['snoozeStamp'] = op.stamp;
    state['snoozeUntil'] = until;
    state['snoozeStamp'] = op.stamp;
    _commitTodo(noteId, actionId, state, {
      'opId': op.opId,
      'kind': 'snooze',
      'lifecycle': state['lifecycle'],
      'at': op.at,
      'until': until,
    }, plan: v);
  }

  /// Writes the authoritative completion state into the note checkbox. A
  /// write failure keeps the durable state and is retried on the next open.
  Future<void> _mirrorActionCompletion(String noteId) async {
    final note = notes.firstWhere((n) => n.id == noteId);
    final completion = {
      for (final a in note.actions)
        a.id: _actionStateRow(_actionKey(noteId, a.id))['completed'] == true,
    };
    if (note.actions.every((a) => a.completed == completion[a.id])) return;
    try {
      await _resolveActions(
        noteId,
        kind: note.kind,
        actions: note.actions,
        completion: completion,
      );
    } on FileSystemException {
      /* Reported through actionState().notePending. */
    } on StateError {
      /* A pending write or rename finishes first; retried later. */
    }
  }

  Future<void> _recoverActionCompletion() async {
    for (final note in notes.where((n) => n.kind == NoteKind.todo)) {
      await _mirrorActionCompletion(note.id);
    }
  }

  bool _validReminderInteraction(NotificationInteraction r) {
    final p = r.payload;
    final scope = base64Url.encode(utf8.encode(vaultStorage.identity));
    return p['kind'] == 'actionReminder' &&
        p['vault'] == vaultStorage.identity &&
        p['noteId'] != null &&
        p['actionId'] != null &&
        int.tryParse(p['lifecycle'] ?? '1') != null &&
        r.id.startsWith('note-agent:$scope:${p['noteId']}:${p['actionId']}:');
  }

  String? _reminderInteractionNote(List<NotificationInteraction> responses) =>
      responses
          .where(
            (r) =>
                r.actionIdentifier == 'default' &&
                _validReminderInteraction(r) &&
                notes.any((n) => n.id == r.payload['noteId']),
          )
          .lastOrNull
          ?.payload['noteId'];

  Future<String?> _applyReminderInteractions(
    List<NotificationInteraction> responses,
  ) async {
    for (final r in responses.where(_validReminderInteraction)) {
      final noteId = r.payload['noteId']!, actionId = r.payload['actionId']!;
      final lifecycle = int.parse(r.payload['lifecycle'] ?? '1');
      try {
        switch (r.actionIdentifier) {
          case 'complete':
            await _completeAction(noteId, actionId, lifecycle: lifecycle);
          case 'snooze':
            if (_actionStateRow(_actionKey(noteId, actionId))['lifecycle'] ==
                lifecycle) {
              final armed = int.tryParse(r.payload['snoozedUntilMs'] ?? '');
              await _snoozeReminder(
                noteId,
                actionId,
                notificationId: r.id,
                armedUntil: armed == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(armed),
              );
            }
        }
      } on StateError {
        /* The action was removed or unconfirmed since this alert was shown. */
      }
    }
    return _reminderInteractionNote(responses);
  }

  Future<void> _reconcileReminders() async {
    // Desired state is durable before any OS interaction. Action decisions and
    // their file-write recovery remain independent from notification failures.
    final active = <String>{};
    for (final note in notes) {
      for (final action in note.actions.where((a) => a.actionConfirmed)) {
        final key = _actionKey(note.id, action.id);
        final state = _actionStateRow(key);
        // Completed or removed items are inactive; their plans are cancelled
        // below. So are reminders missed in the 回收站 until the user decides.
        if (state['completed'] == true ||
            state['removed'] == true ||
            state['held'] != null ||
            state['silenced'] == true) {
          continue;
        }
        active.add(key);
        final rows = _database.select(
          'SELECT payload,removed FROM reminder_plans WHERE vault=? AND action_id=?',
          [vaultStorage.identity, key],
        );
        final old = rows.isEmpty
            ? null
            : jsonDecode(rows.single['payload'] as String)
                  as Map<String, dynamic>;
        final lifecycle = state['lifecycle'] as int;
        final reopenTime = state['time'] as String?;
        var signature = '${action.timeStatus.name}:${action.timeExpression}';
        // First-lifecycle plans keep their original signature so upgrades do
        // not reapply changed defaults to existing reminders.
        if (lifecycle > 1 || reopenTime != null) {
          signature = '$lifecycle:${reopenTime ?? ''}:$signature';
        }
        if (old != null &&
            rows.single['removed'] == 0 &&
            old['signature'] == signature) {
          if (old['text'] != action.text) {
            old['text'] = action.text;
            final expired =
                !DateTime.parse(old['time']).isAfter(_clock()) &&
                (old['status'] == ReminderStatus.scheduled.name ||
                    old['status'] == ReminderStatus.elapsed.name);
            if (!expired) {
              final previousId = old['id'] as String;
              old['revision'] = (old['revision'] as int) + 1;
              old['id'] =
                  '${previousId.substring(0, previousId.lastIndexOf(':'))}:${old['revision']}';
              old['cancel'] = [...?old['cancel'] as List?, previousId];
              old['status'] = ReminderStatus.pending.name;
            }
            _saveReminder(old);
          }
          _applySyncedSnooze(key, state);
          continue;
        }
        final computed = reopenTime != null
            ? _ReminderTime(DateTime.parse(reopenTime), true, 'explicit')
            : _reminderTime(action, note.createdAt.toLocal(), reminderDefaults);
        final revision = (old?['revision'] as int? ?? 0) + 1;
        final scope = base64Url.encode(utf8.encode(vaultStorage.identity));
        _saveReminder({
          'id': 'note-agent:$scope:${note.id}:${action.id}:$revision',
          'revision': revision,
          'lifecycle': lifecycle,
          'key': key,
          'noteId': note.id,
          'actionId': action.id,
          'text': action.text,
          'signature': signature,
          'time': computed.time.toIso8601String(),
          'explicit': computed.explicitTime,
          'rule': computed.rule,
          'timeNeedsConfirmation':
              reopenTime == null &&
              (action.timeStatus == ActionTimeStatus.unresolved ||
                  action.timeStatus == ActionTimeStatus.explicit &&
                      computed.rule == 'tomorrow'),
          'immediate': !computed.time.isAfter(_clock()),
          'status': ReminderStatus.pending.name,
          'cancel': [...?old?['cancel'] as List?, if (old != null) old['id']],
        });
        _applySyncedSnooze(key, state);
      }
    }
    for (final row in _database.select(
      'SELECT payload FROM reminder_plans WHERE vault=? AND removed=0',
      [vaultStorage.identity],
    )) {
      final v = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      if (!active.contains(v['key'])) {
        v['cancel'] = [...?v['cancel'] as List?, v['id']];
        _saveReminder(v, removed: true);
      }
    }
    // The system may keep its permission callback open indefinitely. Desired
    // plans above are durable; OS inspection must not hold local mutations.
    if (_notificationPermissionWaiting) return;
    NotificationSnapshot snapshot;
    try {
      final inspected = await _inspectNotifications();
      if (inspected == null) return;
      snapshot = inspected;
      _notificationPermission = snapshot.permission;
      _notificationTimingExact = snapshot.exactTiming;
      _notificationError = null;
    } catch (error) {
      _notificationPermission = NotificationPermission.unknown;
      _notificationError = '无法核对系统通知：$error';
      return;
    }
    final snoozeMinutes = '${reminderDefaults.snoozeMinutes}';
    for (final row in _database.select(
      'SELECT payload,removed FROM reminder_plans WHERE vault=?',
      [vaultStorage.identity],
    )) {
      final v = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      final removed = row['removed'] == 1;
      try {
        for (final id in (v['cancel'] as List? ?? [])) {
          await _notifications.cancel(id as String);
        }
        v['cancel'] = <String>[];
        _saveReminder(v, removed: removed);
        if (removed) continue;
        final id = v['id'] as String;
        final time = DateTime.parse(v['time']);
        final accepted =
            snapshot.acceptedIds.contains(id) ||
            snapshot.deliveredIds.contains(id);
        if (snapshot.pendingIds.contains(id)) {
          v['status'] = ReminderStatus.scheduled.name;
        } else if (accepted && !time.isAfter(_clock()) ||
            (v['status'] == ReminderStatus.scheduled.name ||
                    v['status'] == ReminderStatus.elapsed.name) &&
                !time.isAfter(_clock())) {
          v['status'] = ReminderStatus.elapsed.name;
        } else if (snapshot.permission != NotificationPermission.allowed) {
          v['status'] = ReminderStatus.blocked.name;
        } else {
          await _notifications.schedule(
            NotificationRequest(
              id: id,
              title: '待办提醒',
              body: v['text'],
              time: time,
              immediate: !time.isAfter(_clock()),
              payload: {
                'kind': 'actionReminder',
                'vault': vaultStorage.identity,
                'noteId': v['noteId'],
                'actionId': v['actionId'],
                'lifecycle': '${v['lifecycle'] ?? 1}',
                // Lets Android postpone natively before the App applies it.
                'snoozeMinutes': snoozeMinutes,
              },
            ),
          );
          v['status'] = ReminderStatus.scheduled.name;
        }
        v['error'] = null;
      } catch (error) {
        v['status'] = ReminderStatus.failed.name;
        v['error'] = '系统通知操作失败，可重试：$error';
        _notificationError = removed
            ? '旧提醒尚未成功取消，请重试核对系统通知。'
            : '部分提醒尚未成功安排，请重试核对系统通知。';
      }
      _saveReminder(v, removed: removed);
    }
  }
}

class ReminderDefaultChange {
  const ReminderDefaultChange._(
    this._key,
    this.noteId,
    this.actionId,
    this.text,
    this.previousTime,
    this.time,
  );
  final String _key, noteId, actionId, text;
  final DateTime previousTime, time;
}

class ReminderDefaultsPreview {
  const ReminderDefaultsPreview._(this.changes, this._fingerprint);
  final List<ReminderDefaultChange> changes;
  final String _fingerprint;
}

class ReminderDefaults {
  const ReminderDefaults({
    this.dateMinute = 540,
    this.morningMinute = 540,
    this.afternoonMinute = 840,
    this.eveningMinute = 1200,
    this.tomorrowMinute = 540,
    this.snoozeMinutes = 30,
  });
  final int dateMinute,
      morningMinute,
      afternoonMinute,
      eveningMinute,
      tomorrowMinute,
      snoozeMinutes;
  Map<String, dynamic> toJson() => {
    'date': dateMinute,
    'morning': morningMinute,
    'afternoon': afternoonMinute,
    'evening': eveningMinute,
    'tomorrow': tomorrowMinute,
    'snooze': snoozeMinutes,
  };
  factory ReminderDefaults.fromJson(Map<String, dynamic> v) => ReminderDefaults(
    dateMinute: v['date'],
    morningMinute: v['morning'],
    afternoonMinute: v['afternoon'],
    eveningMinute: v['evening'],
    tomorrowMinute: v['tomorrow'],
    snoozeMinutes: v['snooze'] ?? 30,
  );
}

class _ReminderTime {
  const _ReminderTime(this.time, this.explicitTime, this.rule);
  final DateTime time;
  final bool explicitTime;
  final String rule;
}

_ReminderTime _reminderTime(
  WorkspaceAction action,
  DateTime now,
  ReminderDefaults defaults,
) {
  var s = action.timeExpression.trim().toLowerCase();
  for (final entry in {
    'day after tomorrow': '后天',
    'tomorrow': '明天',
    'today': '今天',
    'morning': '上午',
    'afternoon': '下午',
    'evening': '晚上',
  }.entries) {
    s = s.replaceAll(entry.key, entry.value);
  }
  s = s.replaceAll(RegExp(r'\s+(at|in the)\s+'), ' ');
  for (final entry in {
    '今早': '今天上午',
    '今晚': '今天晚上',
    '明早': '明天上午',
    '明晚': '明天晚上',
    '早上': '上午',
  }.entries) {
    s = s.replaceAll(entry.key, entry.value);
  }
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  s = s.replaceAllMapped(RegExp(r'[零〇一二两三四五六七八九十]{1,3}(?=点|时|分|刻)'), (m) {
    final value = m[0]!;
    if (value.contains('十')) {
      final parts = value.split('十');
      if (parts.length != 2 || parts[0].length > 1 || parts[1].length > 1) {
        return value;
      }
      return '${(parts[0].isEmpty ? 1 : digits[parts[0]]!) * 10 + (parts[1].isEmpty ? 0 : digits[parts[1]]!)}';
    }
    return '${value.split('').fold<int>(0, (n, d) => n * 10 + digits[d]!)}';
  });
  s = s
      .replaceAll('点半', ':30')
      .replaceAll('点1刻', ':15')
      .replaceAll('点3刻', ':45');

  DateTime day = DateTime(now.year, now.month, now.day);
  if (action.timeStatus != ActionTimeStatus.explicit) {
    return _ReminderTime(
      DateTime(day.year, day.month, day.day + 1, 0, defaults.tomorrowMinute),
      false,
      'tomorrow',
    );
  }
  // Only a conservative set of unambiguous calendar expressions is interpreted.
  // Unsupported expressions remain visible and use the unconfirmed-time default.
  final date = RegExp(r'^(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?').firstMatch(s);
  var rest = s;
  var hasDay = false;
  if (date != null) {
    day = DateTime(
      int.parse(date[1]!),
      int.parse(date[2]!),
      int.parse(date[3]!),
    );
    if (day.month != int.parse(date[2]!) || day.day != int.parse(date[3]!)) {
      return _reminderTime(const WorkspaceAction(text: ''), now, defaults);
    }
    rest = s.substring(date.end).trim().replaceFirst(RegExp(r'^t'), '');
    hasDay = true;
  } else {
    for (final entry in {'今天': 0, '今日': 0, '明天': 1, '明日': 1, '后天': 2}.entries) {
      if (s.startsWith(entry.key)) {
        day = DateTime(day.year, day.month, day.day + entry.value);
        rest = s.substring(entry.key.length).trim();
        hasDay = true;
        break;
      }
    }
  }
  final englishClock = RegExp(r'^(.*?)\s*(am|pm)$').firstMatch(rest);
  final meridiem = englishClock?[2];
  if (englishClock != null) {
    rest = englishClock[1]!.trim();
    if (RegExp(r'^\d{1,2}$').hasMatch(rest)) rest = '$rest:00';
  }
  final exact = RegExp(
    r'^(?:(上午|下午|晚上)\s*)?(\d{1,2})(?:(?::|：)(\d{1,2})|(?:点|時|时)(\d{1,2})?(?:分)?)(?::([0-5]\d)(\.\d+)?)?(z|[+-](?:[01]\d|2[0-3]):?[0-5]\d)?$',
  ).firstMatch(rest);
  if (exact != null) {
    var hour = int.parse(exact[2]!);
    final minute = int.tryParse(exact[3] ?? exact[4] ?? '') ?? 0;
    final second = int.tryParse(exact[5] ?? '') ?? 0;
    final fraction = (exact[6]?.substring(1) ?? '')
        .padRight(6, '0')
        .substring(0, 6);
    final microseconds = int.parse(fraction);
    final daypart = exact[1];
    var unambiguous = hour < 24 && minute < 60;
    if (meridiem != null) {
      unambiguous = unambiguous && hour >= 1 && hour <= 12;
      if (daypart != null) {
        unambiguous =
            unambiguous &&
            hour != 12 &&
            (daypart == '上午' ? meridiem == 'am' : meridiem == 'pm');
      }
      hour = hour % 12 + (meridiem == 'pm' ? 12 : 0);
      if (daypart == '晚上' && hour < 18) unambiguous = false;
      if (daypart == '下午' && (hour < 13 || hour > 17)) unambiguous = false;
    } else if (daypart == '上午') {
      unambiguous = unambiguous && hour >= 1 && hour <= 11;
    } else if (daypart == '下午') {
      // Chinese daypart + twelve does not settle the noon/midnight boundary.
      unambiguous =
          unambiguous && (hour >= 1 && hour <= 5 || hour >= 13 && hour <= 17);
      if (hour < 12) hour += 12;
    } else if (daypart == '晚上') {
      // Early single-digit night clocks may refer to the following day.
      // Keep the original expression for confirmation instead of guessing.
      unambiguous =
          unambiguous && (hour >= 6 && hour <= 11 || hour >= 18 && hour <= 23);
      if (hour < 12) hour += 12;
    }
    final zone = exact[7];
    if (zone != null && date == null) unambiguous = false;
    if (unambiguous) {
      DateTime value;
      if (zone != null) {
        value = DateTime.parse(
          '${date![1]}-${date[2]!.padLeft(2, '0')}-${date[3]!.padLeft(2, '0')}T${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:${second.toString().padLeft(2, '0')}.$fraction$zone',
        ).toLocal();
      } else {
        value = DateTime(
          day.year,
          day.month,
          day.day,
          hour,
          minute,
          second,
          microseconds ~/ 1000,
          microseconds % 1000,
        );
        // Reject calendar normalization, including nonexistent local wall times.
        if (value.year != day.year ||
            value.month != day.month ||
            value.day != day.day ||
            value.hour != hour ||
            value.minute != minute ||
            value.second != second) {
          return _reminderTime(const WorkspaceAction(text: ''), now, defaults);
        }
      }
      return _ReminderTime(value, true, 'explicit');
    }
  }
  final periods = {
    '上午': ('morning', defaults.morningMinute),
    '早上': ('morning', defaults.morningMinute),
    '下午': ('afternoon', defaults.afternoonMinute),
    '晚上': ('evening', defaults.eveningMinute),
  };
  if (periods.containsKey(rest)) {
    final period = periods[rest]!;
    return _ReminderTime(
      DateTime(day.year, day.month, day.day, 0, period.$2),
      false,
      period.$1,
    );
  }
  if (hasDay && rest.isEmpty) {
    return _ReminderTime(
      DateTime(day.year, day.month, day.day, 0, defaults.dateMinute),
      false,
      'date',
    );
  }
  return _reminderTime(const WorkspaceAction(text: ''), now, defaults);
}
