part of 'note_workspace.dart';

enum PendingConfirmationKind { action, topic, content }

/// A typed decision identity; titles and reasons may change without new alerts.
class WorkspacePendingConfirmation {
  const WorkspacePendingConfirmation({
    required this.id,
    required this.noteId,
    required this.subjectId,
    required this.kind,
    required this.reason,
  });
  final String id, noteId, subjectId, reason;
  final PendingConfirmationKind kind;
}

extension _WorkspacePendingConfirmations on NoteWorkspace {
  List<WorkspacePendingConfirmation> _pendingConfirmationItems() =>
      List.unmodifiable([
        for (final n in notes)
          for (final a in n.actions.where((a) => !a.actionConfirmed))
            WorkspacePendingConfirmation(
              id: jsonEncode(['action', n.id, a.id]),
              noteId: n.id,
              subjectId: a.id,
              kind: PendingConfirmationKind.action,
              reason: a.reason,
            ),
        for (final n in pendingActionNotes.where(
          (n) => !n.presentation.needsConfirmation,
        ))
          WorkspacePendingConfirmation(
            id: jsonEncode(['content', n.id]),
            noteId: n.id,
            subjectId: n.id,
            kind: PendingConfirmationKind.content,
            reason: 'reviewRequired',
          ),
        for (final s in pendingTopicSuggestions)
          WorkspacePendingConfirmation(
            id: jsonEncode(['topic', s.noteId, s.id]),
            noteId: s.noteId,
            subjectId: s.id,
            kind: PendingConfirmationKind.topic,
            reason: s.reason,
          ),
      ]);

  Map<String, dynamic>? _pendingNoticeState() {
    final rows = _database.select(
      'SELECT payload FROM pending_notice_state WHERE vault=?',
      [vaultStorage.identity],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
  }

  void _savePendingNoticeState(Map<String, dynamic> state) => _database.execute(
    'INSERT OR REPLACE INTO pending_notice_state(vault,payload) VALUES (?,?)',
    [vaultStorage.identity, jsonEncode(state)],
  );

  Future<void> _reconcilePendingConfirmations() async {
    final current = _pendingConfirmationItems();
    final existing = _pendingNoticeState();
    final state = existing ?? {'events': <dynamic>[], 'groups': <dynamic>[]};
    final events = state['events'] as List;
    final groups = state['groups'] as List;
    final now = _clock();
    NotificationSnapshot? snapshot;
    try {
      snapshot = await _notifications.inspect();
    } catch (_) {
      /* Unknown never permits a send. */
    }
    for (final group in groups.cast<Map>()) {
      if (snapshot?.pendingIds.contains(group['id']) == true ||
          snapshot?.acceptedIds.contains(group['id']) == true ||
          snapshot?.deliveredIds.contains(group['id']) == true) {
        group['accepted'] = true;
      }
    }
    final active = current.map((i) => i.id).toSet();
    for (final event in events) {
      if (!active.contains(event['key'])) event['active'] = false;
    }
    final additions = <Map<String, dynamic>>[];
    for (final item in current) {
      final event = events
          .cast<Map>()
          .where((e) => e['key'] == item.id && e['active'] == true)
          .firstOrNull;
      if (event != null) {
        event['reason'] = item.reason;
        continue;
      }
      final next = <String, dynamic>{
        'id': _createId(),
        'key': item.id,
        'noteId': item.noteId,
        'subjectId': item.subjectId,
        'kind': item.kind.name, 'reason': item.reason, 'active': true,
        // An upgrade adopts its pre-existing list without a notification burst.
        'baseline': existing == null,
      };
      events.add(next);
      if (existing != null) additions.add(next);
    }
    if (additions.isNotEmpty) {
      var group = groups
          .cast<Map>()
          .where(
            (g) =>
                g['cancelled'] != true &&
                (DateTime.parse(g['time']).isAfter(now) ||
                    g['accepted'] != true &&
                        (snapshot != null || g['attempted'] != true)),
          )
          .lastOrNull;
      if (group == null) {
        final scope = base64Url.encode(utf8.encode(vaultStorage.identity));
        group = <String, dynamic>{
          'id': 'note-agent:$scope:pending:${_createId()}',
          'accepted': false,
          'time': now.add(const Duration(seconds: 30)).toIso8601String(),
        };
        groups.add(group);
      }
      for (final event in additions) {
        event['group'] = group['id'];
      }
    }
    // Permission/inspection outages may span several windows. All never-
    // accepted events catch up as one alert instead of a backlog of banners.
    if (snapshot?.permission == NotificationPermission.allowed) {
      final waiting = groups
          .cast<Map>()
          .where((g) => g['cancelled'] != true && g['accepted'] != true)
          .toList();
      if (waiting.length > 1) {
        final target = waiting.first;
        for (final obsolete in waiting.skip(1)) {
          for (final event in events.cast<Map>()) {
            if (event['group'] == obsolete['id']) event['group'] = target['id'];
          }
          obsolete['cancelled'] = true;
        }
      }
    }
    // Persist event acknowledgement and grouping before crossing the OS seam.
    _savePendingNoticeState(state);
    if (snapshot == null) return;
    for (final group in groups.cast<Map>()) {
      if (group['cancelled'] == true) continue;
      final id = group['id'] as String;
      final time = DateTime.parse(group['time']);
      final count = events
          .cast<Map>()
          .where((e) => e['active'] == true && e['group'] == id)
          .map((e) => e['noteId'])
          .toSet()
          .length;
      try {
        if (count == 0) {
          await _notifications.cancel(id);
          group['cancelled'] = true;
        } else if (group['accepted'] == true && !time.isAfter(now)) {
          // OS acceptance remains acknowledged even if its delivered list clears.
          _savePendingNoticeState(state);
          continue;
        } else if (snapshot.permission == NotificationPermission.allowed) {
          final signature = '$count:${group['time']}';
          if (group['signature'] != signature || group['accepted'] != true) {
            group['attempted'] = true;
            _savePendingNoticeState(state);
            await _notifications.schedule(
              NotificationRequest(
                id: id,
                title: '有待确认内容',
                body: '$count 条笔记有待确认内容，点击查看。',
                time: time,
                immediate: !time.isAfter(now),
                payload: {
                  'kind': 'pendingConfirmation',
                  'vault': vaultStorage.identity,
                  'groupId': id,
                },
              ),
            );
            group['signature'] = signature;
            group['accepted'] = true;
          }
        }
        group.remove('error');
      } catch (_) {
        group['error'] = '待确认通知尚未安排，列表中的内容仍可处理。';
      }
      _savePendingNoticeState(state);
    }
  }

  Future<bool> _takePendingConfirmationNavigation() async {
    if (_notifications is! NotificationInteractionPort) return false;
    final responses = await (_notifications as NotificationInteractionPort)
        .takeInteractions(
          kind: 'pendingConfirmation',
          vault: vaultStorage.identity,
        );
    final state = _pendingNoticeState();
    final groups = (state?['groups'] as List? ?? []).cast<Map>();
    return responses.any(
      (r) =>
          r.actionIdentifier == 'default' &&
          r.payload['kind'] == 'pendingConfirmation' &&
          r.payload['vault'] == vaultStorage.identity &&
          r.payload['groupId'] == r.id &&
          groups.any(
            (g) =>
                g['id'] == r.id &&
                g['cancelled'] != true &&
                g['accepted'] == true,
          ),
    );
  }
}
