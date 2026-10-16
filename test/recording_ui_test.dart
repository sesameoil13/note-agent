import 'dart:io';
import 'dart:ui' as ui;

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
  testWidgets(
    'compact recording actions expose named accessible press actions',
    (tester) async {
      final audio = _AudioInput();
      final setup = await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(
          'note-agent-t08-accessibility-',
        );
        var identity = 0;
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${temporary.path}/local'),
          vaultDirectory: await Directory('${temporary.path}/vault').create(),
          audioPlatform: audio,
          createId: () => 'accessible-${++identity}',
        );
        await workspace.captureText(title: '无障碍测试', text: '通过读屏使用收集控制。');
        await workspace.startRecording();
        audio.duration = const Duration(seconds: 15);
        await workspace.stopRecording();
        return (temporary, workspace);
      });
      final (temporary, workspace) = setup!;
      addTearDown(() async {
        await tester.runAsync(() async {
          await workspace.close();
          await temporary.delete(recursive: true);
        });
      });
      tester.view.physicalSize = const Size(800, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
        for (final label in ['录音', '最近记录', '新建文字']) {
          final data = tester
              .getSemantics(find.byTooltip(label))
              .getSemanticsData();
          expect(data.label, label);
          expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
        }
        void press(String label) {
          final node = tester.getSemantics(find.byTooltip(label));
          tester.binding.performSemanticsAction(
            ui.SemanticsActionEvent(
              type: ui.SemanticsAction.tap,
              viewId: tester.view.viewId,
              nodeId: node.id,
            ),
          );
        }

        press('录音');
        await tester.pumpAndSettle();
        expect(find.text('收集录音'), findsOneWidget);
        final play = tester
            .getSemantics(find.byTooltip('回放原音频'))
            .getSemanticsData();
        expect(play.label, '回放原音频');
        expect(play.hasAction(ui.SemanticsAction.tap), isTrue);
        await tester.runAsync(() async {
          press('回放原音频');
          for (var attempt = 0; attempt < 200; attempt++) {
            if (workspace.playback.isPlaying) return;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          fail('Accessible playback did not start');
        });
        await tester.pumpAndSettle();
        final stop = tester
            .getSemantics(find.byTooltip('停止回放'))
            .getSemanticsData();
        expect(stop.label, '停止回放');
        expect(stop.hasAction(ui.SemanticsAction.tap), isTrue);
        await tester.runAsync(() async {
          press('停止回放');
          for (var attempt = 0; attempt < 200; attempt++) {
            if (!workspace.playback.isPlaying) return;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          fail('Accessible playback did not stop');
        });
        await tester.pumpAndSettle();
        press('新建文字');
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, '正文'), findsOneWidget);
        press('最近记录');
        await tester.pumpAndSettle();
        expect(find.text('无障碍测试'), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets(
    'unacknowledged audio export stays unverified even when the vault copy exists',
    (tester) async {
      final audio = _AudioInput();
      final setup = await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(
          'note-agent-t08-ack-',
        );
        final directory = await Directory('${temporary.path}/vault').create();
        final storage = _UnacknowledgedAudioVault(
          Directory(await directory.resolveSymbolicLinks()),
        );
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${temporary.path}/local'),
          vaultStorage: storage,
          audioPlatform: audio,
          createId: () => 'unacknowledged-recording',
        );
        await workspace.startRecording();
        audio.duration = const Duration(seconds: 15);
        final recording = await workspace.stopRecording();
        expect(recording.status, RecordingStatus.exportFailed);
        expect(
          await File(recording.sourcePath).readAsBytes(),
          await File(recording.originalPath).readAsBytes(),
        );
        await workspace.playRecording(recording.id);
        expect(workspace.playback.isPlaying, isTrue);
        await workspace.stopPlayback();
        return (temporary, workspace, storage);
      });
      final (temporary, workspace, storage) = setup!;
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
      expect(find.text('本机原音频已保留 · 笔记库写入未确认'), findsOneWidget);
      expect(find.text('本机原音频已保留 · 笔记库未写入'), findsNothing);
      storage.failAfterCommit = false;
      await _tapAndWait(
        tester,
        '重试写入笔记库',
        () => workspace.recordings.single.status == RecordingStatus.localSaved,
      );
      expect(workspace.recordings, hasLength(1));
      expect(find.text('本机原音频已保存 · 尚未转写'), findsOneWidget);
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

/// A file-system boundary may commit a complete source and lose its response.
class _UnacknowledgedAudioVault extends DirectoryVaultStorage {
  _UnacknowledgedAudioVault(super.directory);
  bool failAfterCommit = true;
  @override
  Future<void> publishFile(
    String relativePath,
    File original,
    String operationId,
  ) async {
    await super.publishFile(relativePath, original, operationId);
    if (failAfterCommit) throw const FileSystemException('写入确认暂不可用，本机原音频仍保留。');
  }
}
