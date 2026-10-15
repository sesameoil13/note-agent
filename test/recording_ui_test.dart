import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  testWidgets(
    'recording controls save a playable original without claiming transcription',
    (tester) async {
      final audio = _AudioInput();
      final setup = await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(
          'note-agent-t08-ui-',
        );
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${temporary.path}/local'),
          vaultDirectory: await Directory('${temporary.path}/vault').create(),
          audioPlatform: audio,
          createId: () => 'visible-recording',
        );
        return (temporary, workspace);
      });
      final (temporary, workspace) = setup!;
      addTearDown(() async {
        await tester.runAsync(() async {
          await workspace.close();
          await temporary.delete(recursive: true);
        });
      });
      tester.view.physicalSize = const Size(1280, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
      await tester.tap(find.text('录音'));
      await tester.pumpAndSettle();
      await _tapAndWait(
        tester,
        '开始录音',
        () => workspace.recording.phase == RecordingPhase.recording,
      );
      expect(find.text('录音中'), findsOneWidget);
      audio.duration = const Duration(seconds: 15);
      await _tapAndWait(
        tester,
        '暂停',
        () => workspace.recording.phase == RecordingPhase.paused,
      );
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('00:15'), findsWidgets);
      await _tapAndWait(
        tester,
        '继续录音',
        () => workspace.recording.phase == RecordingPhase.recording,
      );
      audio.duration = const Duration(seconds: 20);
      await _tapAndWait(
        tester,
        '结束并保存',
        () => workspace.recordings.single.status == RecordingStatus.localSaved,
      );
      expect(find.text('本机原音频已保存 · 尚未转写'), findsOneWidget);
      expect(workspace.notes, isEmpty);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('回放原音频'));
        for (var attempt = 0; attempt < 200; attempt++) {
          if (workspace.playback.isPlaying) return;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        fail('Playback did not start');
      });
      await tester.pumpAndSettle();
      expect(workspace.playback.isPlaying, isTrue);
      expect(find.byTooltip('停止回放'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Future<void> _tapAndWait(
  WidgetTester tester,
  String label,
  bool Function() done,
) async {
  await tester.runAsync(() async {
    await tester.tap(find.text(label));
    for (var attempt = 0; attempt < 200; attempt++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('The action did not finish: $label');
  });
  await tester.pumpAndSettle();
}

class _AudioInput implements AudioPlatform {
  Duration duration = Duration.zero;
  AudioCapturePhase phase = AudioCapturePhase.stopped;
  @override
  Future<void> startRecording(String originalPath) async {
    await File(originalPath)
        .writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112], flush: true);
    phase = AudioCapturePhase.recording;
  }

  @override
  Future<void> pauseRecording() async => phase = AudioCapturePhase.paused;
  @override
  Future<void> resumeRecording() async => phase = AudioCapturePhase.recording;
  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async =>
      AudioCaptureSnapshot(phase: phase, duration: duration, level: 0.5);
  @override
  Future<AudioCaptureSnapshot> stopRecording() async {
    phase = AudioCapturePhase.stopped;
    return recordingSnapshot();
  }

  @override
  Future<Duration> inspectRecording(String path) async => duration;
  @override
  Future<void> play(String path) async {}
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<AudioPlaybackSnapshot> playbackSnapshot() async =>
      const AudioPlaybackSnapshot(isPlaying: true, position: Duration.zero);
}
