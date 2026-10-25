/// To-do lifecycle and deletion-mark merge rules (ADR 0002), mirrored by the
/// Worker's services/pairing/src/todos.mjs. Both are run against the shared
/// cases in test/fixtures/todo-merge-cases.json so the two cannot drift.
library;

import 'dart:math';

/// Stable ordering for "later device time wins" (ADR 0002); the operation id
/// breaks ties. Identical to the Worker's stamp.
String todoStamp(int at, String opId) =>
    '${at.toString().padLeft(16, '0')}:$opId';

/// The same commutative, idempotent join the Worker applies: a higher
/// lifecycle wins, completion wins within a lifecycle, later stamps win between
/// snoozes or reopen times, and removal is a tombstone. Joining an older or
/// duplicated state never moves a newer one backwards.
Map<String, dynamic> joinTodoStates(
  Map<String, dynamic>? a,
  Map<String, dynamic> b,
) {
  if (a == null) return normalizeTodoState(b);
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
  return normalizeTodoState({
    ...r,
    'removed': a['removed'] == true || b['removed'] == true,
  });
}

Map<String, dynamic> normalizeTodoState(Map<String, dynamic> s) {
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

/// The Worker's joinMark: a purge is final; otherwise the later device time
/// (operation id as tiebreak) wins between deletion and restore.
Map<String, dynamic> joinNoteMarks(
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
