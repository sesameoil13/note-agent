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
    this.error,
  });
  final String id, noteId, actionId, text;
  final DateTime time;
  final bool explicitTime, immediate, timeNeedsConfirmation;
  final ReminderStatus status;
  final String? error;
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
      if (v['explicit'] == true) continue;
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

  Future<void> _reconcileReminders() async {
    // Desired state is durable before any OS interaction. Action decisions and
    // their file-write recovery remain independent from notification failures.
    final active = <String>{};
    for (final note in notes) {
      for (final action in note.actions.where((a) => a.actionConfirmed)) {
        final key = '${note.id}:${action.id}';
        active.add(key);
        final rows = _database.select(
          'SELECT payload,removed FROM reminder_plans WHERE vault=? AND action_id=?',
          [vaultStorage.identity, key],
        );
        final old = rows.isEmpty
            ? null
            : jsonDecode(rows.single['payload'] as String)
                  as Map<String, dynamic>;
        final signature = '${action.timeStatus.name}:${action.timeExpression}';
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
          continue;
        }
        final computed = _reminderTime(
          action,
          note.createdAt.toLocal(),
          reminderDefaults,
        );
        final revision = (old?['revision'] as int? ?? 0) + 1;
        final scope = base64Url.encode(utf8.encode(vaultStorage.identity));
        _saveReminder({
          'id': 'note-agent:$scope:${note.id}:${action.id}:$revision',
          'revision': revision,
          'key': key,
          'noteId': note.id,
          'actionId': action.id,
          'text': action.text,
          'signature': signature,
          'time': computed.time.toIso8601String(),
          'explicit': computed.explicitTime,
          'rule': computed.rule,
          'timeNeedsConfirmation':
              action.timeStatus == ActionTimeStatus.unresolved ||
              action.timeStatus == ActionTimeStatus.explicit &&
                  computed.rule == 'tomorrow',
          'immediate': !computed.time.isAfter(_clock()),
          'status': ReminderStatus.pending.name,
          'cancel': [...?old?['cancel'] as List?, if (old != null) old['id']],
        });
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
      _notificationError = null;
    } catch (error) {
      _notificationPermission = NotificationPermission.unknown;
      _notificationError = '无法核对系统通知：$error';
      return;
    }
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
                'noteId': v['noteId'],
                'actionId': v['actionId'],
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
  });
  final int dateMinute,
      morningMinute,
      afternoonMinute,
      eveningMinute,
      tomorrowMinute;
  Map<String, dynamic> toJson() => {
    'date': dateMinute,
    'morning': morningMinute,
    'afternoon': afternoonMinute,
    'evening': eveningMinute,
    'tomorrow': tomorrowMinute,
  };
  factory ReminderDefaults.fromJson(Map<String, dynamic> v) => ReminderDefaults(
    dateMinute: v['date'],
    morningMinute: v['morning'],
    afternoonMinute: v['afternoon'],
    eveningMinute: v['evening'],
    tomorrowMinute: v['tomorrow'],
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
