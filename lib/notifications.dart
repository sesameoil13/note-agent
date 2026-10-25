import 'dart:async';

/// OS notification boundary shared by reminders and future grouped notices.
/// Scheduling confirms OS acceptance only; it never proves actual delivery.
enum NotificationPermission {
  unknown,
  notDetermined,
  denied,
  allowed,
  unavailable,
}

class NotificationRequest {
  const NotificationRequest({
    required this.id,
    required this.title,
    required this.body,
    required this.time,
    required this.payload,
    this.immediate = false,
  });
  final String id, title, body;
  final DateTime time;
  final bool immediate;
  final Map<String, String> payload;
}

class NotificationSnapshot {
  const NotificationSnapshot({
    required this.permission,
    this.pendingIds = const {},
    this.acceptedIds = const {},
    this.deliveredIds = const {},
    this.exactTiming = true,
  });
  final NotificationPermission permission;

  /// False when the OS may defer alarms (Android without exact-alarm access);
  /// reminders are still scheduled but may arrive late.
  final bool exactTiming;
  final Set<String> pendingIds, acceptedIds, deliveredIds;
}

abstract interface class NotificationPort {
  Future<NotificationSnapshot> inspect();

  /// Only call after an explicit user gesture, never while opening/reconciling.
  Future<NotificationPermission> requestPermission();
  Future<void> schedule(NotificationRequest request);
  Future<void> cancel(String id);
}

class UnavailableNotifications implements NotificationPort {
  const UnavailableNotifications();
  @override
  Future<NotificationSnapshot> inspect() async => const NotificationSnapshot(
    permission: NotificationPermission.unavailable,
  );
  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.unavailable;
  @override
  Future<void> schedule(NotificationRequest request) async =>
      throw UnsupportedError('当前平台尚未连接系统通知。');
  @override
  Future<void> cancel(String id) async {}
}

/// Optional interaction seam; existing scheduling-only adapters remain valid.
class NotificationInteraction {
  const NotificationInteraction({
    required this.id,
    required this.payload,
    this.actionIdentifier = 'default',
  });
  final String id;
  final Map<String, String> payload;
  final String actionIdentifier;
}

abstract interface class NotificationInteractionPort {
  Stream<void> get interactionSignals;

  /// Drains durable responses, including those received before Dart attached.
  Future<List<NotificationInteraction>> takeInteractions({
    required String kind,
    String? vault,
  });
}
