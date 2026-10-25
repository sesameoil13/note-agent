import 'dart:async';

import 'package:flutter/services.dart';

import 'notifications.dart';

/// macOS, Android and Windows local notification adapter; inspect never prompts.
class MethodChannelNotifications
    implements NotificationPort, NotificationInteractionPort {
  MethodChannelNotifications() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'interactionAvailable') _signals.add(null);
      // Windows also reports waking from sleep: due toasts and plans need the
      // same re-check as a regained network.
      if (call.method == 'networkAvailable' || call.method == 'systemResumed') {
        _network.add(null);
      }
    });
  }
  final _signals = StreamController<void>.broadcast();
  final _network = StreamController<void>.broadcast();

  /// macOS, Android and Windows report a regained network, and Windows a wake from
  /// sleep, so the App can re-check reminders.
  Stream<void> get connectivitySignals => _network.stream;
  @override
  Stream<void> get interactionSignals => _signals.stream;
  @override
  Future<List<NotificationInteraction>> takeInteractions({
    required String kind,
    String? vault,
  }) async {
    final values =
        await _channel.invokeListMethod<dynamic>('takeInteractions', {
          'kind': kind,
          'vault': ?vault,
        }) ??
        [];
    return values.map((value) {
      final v = (value as Map).cast<String, dynamic>();
      return NotificationInteraction(
        id: v['id'] as String,
        actionIdentifier: v['actionIdentifier'] as String? ?? 'default',
        payload: (v['payload'] as Map).cast<String, String>(),
      );
    }).toList();
  }

  static const _channel = MethodChannel('dev.noteagent/notifications');
  @override
  Future<NotificationSnapshot> inspect() async {
    final value = (await _channel.invokeMapMethod<String, dynamic>('inspect'))!;
    Set<String> ids(String key) =>
        (value[key] as List? ?? []).cast<String>().toSet();
    return NotificationSnapshot(
      permission: NotificationPermission.values.byName(value['permission']),
      pendingIds: ids('pending'),
      acceptedIds: ids('accepted'),
      deliveredIds: ids('delivered'),
      exactTiming: value['exactTiming'] as bool? ?? true,
    );
  }

  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.values.byName(
        (await _channel.invokeMethod<String>('requestPermission'))!,
      );
  @override
  Future<void> schedule(NotificationRequest request) =>
      _channel.invokeMethod<void>('schedule', {
        'id': request.id,
        'title': request.title,
        'body': request.body,
        'timeMs': request.time.millisecondsSinceEpoch,
        'immediate': request.immediate,
        'payload': request.payload,
      });
  @override
  Future<void> cancel(String id) =>
      _channel.invokeMethod<void>('cancel', {'id': id});
}
