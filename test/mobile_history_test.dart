import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

import 'audio_queue_test.dart' show wave;

void main() {
  testWidgets(
    'browsing phone history leaves an active recording running with the same original',
    (tester) async {
      final audio = _AudioBoundary();
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'active-phone-history-',
        );
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          audioPlatform: audio,
        );
        await workspace.startRecording();
        return (root, workspace);
      }))!;
      final (root, workspace) = fixture;
      final original = workspace.recordings.single;
      addTearDown(
        () => tester.runAsync(() async {
          await workspace.close();
          await root.delete(recursive: true);
        }),
      );
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
      await tester.tap(find.text('历史记录'));
      await tester.pumpAndSettle();
      expect(workspace.recording.isActive, isTrue);
      expect(audio.phase, AudioCapturePhase.recording);
      expect(workspace.recording.recordingId, original.id);
      expect(workspace.recordings.single.originalPath, original.originalPath);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.runAsync(workspace.stopRecording);
      expect(workspace.recordings.single.status, RecordingStatus.localSaved);
      expect(workspace.recordings.single.id, original.id);
      expect(
        await tester.runAsync(() => File(original.originalPath).readAsBytes()),
        wave(seconds: 20),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final withNote in [true, false]) {
    testWidgets(
      'phone history visibly reaches ${withNote ? 'saved note and' : 'only'} saved original after restart',
      (tester) async {
        final audio = _AudioBoundary();
        final fixture = (await tester.runAsync(() async {
          final root = await Directory.systemTemp.createTemp('mobile-history-');
          final local = Directory('${root.path}/local');
          final vault = await Directory('${root.path}/vault').create();
          var workspace = await NoteWorkspace.open(
            localDirectory: local,
            vaultDirectory: vault,
            audioPlatform: audio,
          );
          if (withNote) {
            await workspace.captureText(title: '已保存的想法', text: '重新打开后仍能找回正文。');
          }
          await workspace.startRecording();
          await workspace.stopRecording();
          expect(
            workspace.recordings.single.duration,
            const Duration(seconds: 20),
          );
          await workspace.close();
          workspace = await NoteWorkspace.open(
            localDirectory: local,
            vaultDirectory: vault,
            audioPlatform: audio,
          );
          return (root, workspace);
        }))!;
        final (root, workspace) = fixture;
        addTearDown(
          () => tester.runAsync(() async {
            await workspace.close();
            await root.delete(recursive: true);
          }),
        );
        tester.view.physicalSize = Size(withNote ? 412 : 360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.textScaleFactorTestValue = withNote ? 1 : 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
        await tester.pumpAndSettle();
        final history = withNote ? find.text('历史记录') : find.byTooltip('最近记录');
        expect(find.text('历史记录').hitTestable(), findsOneWidget);
        expect(history.hitTestable(), findsOneWidget);
        await tester.tap(history);
        await tester.pumpAndSettle();
        if (withNote) {
          expect(find.text('已保存的想法'), findsOneWidget);
          await tester.tap(find.text('原始录音 1'));
          await tester.pumpAndSettle();
        }
        expect(find.byTooltip('回放原音频').hitTestable(), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.byTooltip('回放原音频'));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
        expect(workspace.playback.isPlaying, isTrue);
        expect(audio.played, workspace.recordings.single.originalPath);
        expect(
          await tester.runAsync(() => File(audio.played!).readAsBytes()),
          wave(seconds: 20),
        );
        if (withNote) {
          await tester.pageBack();
          await tester.pumpAndSettle();
          await tester.tap(find.text('历史记录'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('已保存的想法'));
          await tester.pumpAndSettle();
          expect(find.text('重新打开后仍能找回正文。'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'empty phone history opens a clear empty state instead of ignoring the action',
    (tester) async {
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'empty-phone-history-',
        );
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
        );
        return (root, workspace);
      }))!;
      final (root, workspace) = fixture;
      addTearDown(
        () => tester.runAsync(() async {
          await workspace.close();
          await root.delete(recursive: true);
        }),
      );
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
      await tester.tap(find.text('历史记录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有记录。'), findsOneWidget);
      await tester.tap(find.text('原始录音 0'));
      await tester.pumpAndSettle();
      expect(find.text('保存的原音频会出现在这里。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _AudioBoundary implements AudioPlatform {
  String? played;
  AudioCapturePhase phase = AudioCapturePhase.stopped;
  @override
  Future<void> startRecording(String path) async {
    await File(path).writeAsBytes(wave(seconds: 20));
    phase = AudioCapturePhase.recording;
  }

  @override
  Future<void> pauseRecording() async {}
  @override
  Future<void> resumeRecording() async {}
  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async =>
      AudioCaptureSnapshot(phase: phase, duration: const Duration(seconds: 20));
  @override
  Future<AudioCaptureSnapshot> stopRecording() {
    phase = AudioCapturePhase.stopped;
    return recordingSnapshot();
  }

  @override
  Future<Duration> inspectRecording(String path) async =>
      const Duration(seconds: 20);
  @override
  Future<void> play(String path) async => played = path;
  @override
  Future<void> stopPlayback() async => played = null;
  @override
  Future<AudioPlaybackSnapshot> playbackSnapshot() async =>
      AudioPlaybackSnapshot(isPlaying: played != null, position: Duration.zero);
}
