import 'dart:async';

import 'package:note_agent/note_workspace.dart';

class PendingNotifications
    implements NotificationPort, NotificationInteractionPort {
  NotificationPermission permission = NotificationPermission.allowed;
  int schedules = 0, permissionRequests = 0;
  bool failInspect = false, failSchedule = false, exactTiming = true;
  final pending = <String, NotificationRequest>{};
  final accepted = <String>{};
  final interactions = <NotificationInteraction>[];
  final signals = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get interactionSignals => signals.stream;
  @override
  Future<List<NotificationInteraction>> takeInteractions({
    required String kind,
    String? vault,
  }) async {
    final result = interactions
        .where(
          (i) =>
              i.payload['kind'] == kind &&
              (vault == null || i.payload['vault'] == vault),
        )
        .toList();
    interactions.removeWhere(
      (i) =>
          i.payload['kind'] == kind &&
          (vault == null || i.payload['vault'] == vault),
    );
    return result;
  }

  @override
  Future<NotificationSnapshot> inspect() async {
    if (failInspect) throw StateError('controlled inspect failure');
    return NotificationSnapshot(
      permission: permission,
      pendingIds: pending.keys.toSet(),
      acceptedIds: accepted,
      exactTiming: exactTiming,
    );
  }

  @override
  Future<NotificationPermission> requestPermission() async {
    permissionRequests++;
    return permission = NotificationPermission.allowed;
  }

  @override
  Future<void> schedule(NotificationRequest r) async {
    if (failSchedule) throw StateError('controlled schedule failure');
    schedules++;
    pending[r.id] = r;
    accepted.add(r.id);
  }

  @override
  Future<void> cancel(String id) async {
    pending.remove(id);
    accepted.remove(id);
  }
}
