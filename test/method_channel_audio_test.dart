import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/audio_platform.dart';
import 'package:note_agent/method_channel_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.noteagent/audio');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'a recorder that finalizes on exit reports that exact original as stopped',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'phase': 'stopped', 'durationMs': 15200};
      });
      final audio = MethodChannelAudioPlatform(nativeRecovery: true);
      final snapshot = await audio.recoverRecording(r'C:\w\recordings\a.m4a');
      expect(snapshot!.phase, AudioCapturePhase.stopped);
      expect(snapshot.duration, const Duration(milliseconds: 15200));
      expect(calls.single.method, 'recoverRecording');
      expect(calls.single.arguments, {'path': r'C:\w\recordings\a.m4a'});
    },
  );

  test(
    'a recorder without native recovery never claims a completion',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'phase': 'stopped', 'durationMs': 15200};
      });
      final audio = MethodChannelAudioPlatform(nativeRecovery: false);
      expect(await audio.recoverRecording('/w/recordings/a.m4a'), isNull);
      expect(calls, isEmpty);
    },
  );
}
