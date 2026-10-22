import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/notification_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native adapter drains only requested interaction kind and vault and forwards foreground signals without requesting permission', () async {
    const channel = MethodChannel('dev.noteagent/notifications');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'takeInteractions') {
            return [
              {
                'id': 'group-1',
                'payload': {
                  'kind': 'pendingConfirmation',
                  'vault': 'vault-a',
                  'groupId': 'group-1',
                },
              },
            ];
          }
          if (call.method == 'inspect') {
            return {
              'permission': 'denied',
              'pending': [],
              'accepted': [],
              'delivered': [],
            };
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final port = MethodChannelNotifications();
    var signals = 0;
    final subscription = port.interactionSignals.listen((_) => signals++);
    addTearDown(subscription.cancel);
    final responses = await port.takeInteractions(
      kind: 'pendingConfirmation',
      vault: 'vault-a',
    );
    expect(responses.single.id, 'group-1');
    expect(calls.single.arguments, {
      'kind': 'pendingConfirmation',
      'vault': 'vault-a',
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final reply = await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('interactionAvailable'),
      ),
      (ByteData? _) {},
    );
    expect(const StandardMethodCodec().decodeEnvelope(reply!), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(signals, 1);
    expect(calls.map((c) => c.method), ['takeInteractions']);
  });
}
