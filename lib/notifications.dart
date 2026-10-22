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
  });
  final NotificationPermission permission;
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
