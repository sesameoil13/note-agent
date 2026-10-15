import 'package:flutter/services.dart';

import 'audio_platform.dart';

/// macOS AVFoundation bridge. Other platforms explicitly report unavailable.
class MethodChannelAudioPlatform implements AudioPlatform {
  static const _channel = MethodChannel('dev.noteagent/audio');
  @override
  Future<void> startRecording(String originalPath) =>
      _channel.invokeMethod<void>('startRecording', {'path': originalPath});
  @override
  Future<void> pauseRecording() =>
      _channel.invokeMethod<void>('pauseRecording');
  @override
  Future<void> resumeRecording() =>
      _channel.invokeMethod<void>('resumeRecording');
  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async => _capture(
    await _channel.invokeMapMethod<String, dynamic>('recordingSnapshot'),
  );
  @override
  Future<AudioCaptureSnapshot> stopRecording() async => _capture(
    await _channel.invokeMapMethod<String, dynamic>('stopRecording'),
  );
  AudioCaptureSnapshot _capture(Map<String, dynamic>? value) =>
      AudioCaptureSnapshot(
        phase: AudioCapturePhase.values.byName(value!['phase'] as String),
        duration: Duration(milliseconds: (value['durationMs'] as num).round()),
        level: (value['level'] as num?)?.toDouble() ?? 0,
        error: value['error'] as String?,
      );
  @override
  Future<Duration> inspectRecording(String originalPath) async => Duration(
    milliseconds: (await _channel.invokeMethod<num>('inspectRecording', {
      'path': originalPath,
    }))!.round(),
  );
  @override
  Future<void> play(String originalPath) =>
      _channel.invokeMethod<void>('play', {'path': originalPath});
  @override
  Future<void> stopPlayback() => _channel.invokeMethod<void>('stopPlayback');
  @override
  Future<AudioPlaybackSnapshot> playbackSnapshot() async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'playbackSnapshot',
    );
    return AudioPlaybackSnapshot(
      isPlaying: value!['isPlaying'] as bool,
      position: Duration(milliseconds: (value['positionMs'] as num).round()),
    );
  }
}
