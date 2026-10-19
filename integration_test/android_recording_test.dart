import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:note_agent/method_channel_audio.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/workspace_platform.dart';

/// Root-owned physical microphone run only. The two explicit guards prevent a
/// generic integration-test command from recording or writing a personal vault.
/// Lock screen, notification actions, denial and process death remain manual.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android microphone saves a paused original and reopens it',
    (tester) async {
      const expectedVault = String.fromEnvironment('ANDROID_TEST_VAULT_NAME');
      expect(expectedVault, startsWith('NoteAgent-Test-'));
      final location = await WorkspacePlatform().restoreLocation();
      expect(location.vaultStorage!.displayName, expectedVault);
      expect(location.authorizationError, isNull);
      final id = 'android-recording-${DateTime.now().microsecondsSinceEpoch}';
      var workspace = await NoteWorkspace.open(
        localDirectory: location.localDirectory,
        vaultStorage: location.vaultStorage,
        audioPlatform: MethodChannelAudioPlatform(),
        createId: () => id,
      );
      await workspace.startRecording();
      await Future<void>.delayed(const Duration(seconds: 15));
      await workspace.pauseRecording();
      final pausedAt = workspace.recording.duration;
      expect(workspace.recording.phase, RecordingPhase.paused);
      await Future<void>.delayed(const Duration(seconds: 3));
      await workspace.refreshRecording();
      expect(workspace.recording.duration, pausedAt);
      await workspace.resumeRecording();
      await Future<void>.delayed(const Duration(seconds: 5));
      final saved = await workspace.stopRecording();
      expect(saved.id, id);
      expect(saved.duration.inMilliseconds, inInclusiveRange(18500, 24000));
      expect(saved.byteLength, inInclusiveRange(1000, 5000000));
      expect(saved.status, RecordingStatus.localSaved, reason: saved.error);
      final original = await File(saved.originalPath).readAsBytes();
      final metadata = await MethodChannelAudioPlatform().inspectAudioSource(
        saved.originalPath,
      );
      expect(metadata.codec, 'AAC');
      expect(metadata.channels, 1);
      expect(metadata.sampleRate, 22050);
      await workspace.playRecording(id);
      await Future<void>.delayed(const Duration(seconds: 2));
      await workspace.refreshPlayback();
      expect(workspace.playback.position, greaterThan(Duration.zero));
      await workspace.stopPlayback();
      await workspace.close();
      workspace = await NoteWorkspace.open(
        localDirectory: location.localDirectory,
        vaultStorage: location.vaultStorage,
        audioPlatform: MethodChannelAudioPlatform(),
      );
      final restored = workspace.recordings.singleWhere((r) => r.id == id);
      expect(restored.status, RecordingStatus.localSaved);
      expect(restored.duration, saved.duration);
      expect(await File(restored.originalPath).readAsBytes(), original);
      expect(
        workspace.audioSources.singleWhere((s) => s.id == id).originalSaved,
        isTrue,
      );
      await workspace.close();
    },
    skip:
        !Platform.isAndroid ||
        !const bool.fromEnvironment('ALLOW_ANDROID_MICROPHONE_TEST'),
  );
}
