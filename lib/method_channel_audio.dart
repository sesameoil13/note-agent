import 'package:flutter/services.dart';

import 'audio_platform.dart';
import 'audio_sources.dart';

/// macOS AVFoundation bridge. Other platforms explicitly report unavailable.
class MethodChannelAudioPlatform
    implements AudioPlatform, AudioSourceInspector, AudioSourcePlayer {
  static const _channel = MethodChannel('dev.noteagent/audio');

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw AudioPlatformFailure(error.message ?? '音频操作未完成，现有原文件已保留。');
    } on MissingPluginException {
      throw const AudioPlatformFailure('此平台尚未接入录音。');
    }
  }

  Future<Map<String, dynamic>> _map(String method) async =>
      ((await _invoke<Object?>(method)) as Map).cast<String, dynamic>();

  @override
  Future<AudioSourceMetadata> inspectAudioSource(String privatePath) async {
    try {
      final value = (await _channel.invokeMapMethod<String, dynamic>(
        'inspectAudioSource',
        {'path': privatePath},
      ))!;
      return AudioSourceMetadata.fromJson(value);
    } on PlatformException catch (error) {
      throw AudioInspectionFailure(
        error.message ?? '此音频无法检查，原件已保留。',
        retryable: error.code == 'inspection_busy',
      );
    }
  }

  @override
  Future<void> playAudioSource(String privatePath) =>
      _invoke<void>('playAudioSource', {'path': privatePath});

  @override
  Future<void> startRecording(String originalPath) =>
      _invoke<void>('startRecording', {'path': originalPath});
  @override
  Future<void> pauseRecording() => _invoke<void>('pauseRecording');
  @override
  Future<void> resumeRecording() => _invoke<void>('resumeRecording');
  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async =>
      _capture(await _map('recordingSnapshot'));
  @override
  Future<AudioCaptureSnapshot> stopRecording() async =>
      _capture(await _map('stopRecording'));
  AudioCaptureSnapshot _capture(Map<String, dynamic>? value) =>
      AudioCaptureSnapshot(
        phase: AudioCapturePhase.values.byName(value!['phase'] as String),
        duration: Duration(milliseconds: (value['durationMs'] as num).round()),
        level: (value['level'] as num?)?.toDouble() ?? 0,
        error: value['error'] as String?,
      );
  @override
  Future<Duration> inspectRecording(String originalPath) async => Duration(
    milliseconds: (await _invoke<num>('inspectRecording', {
      'path': originalPath,
    }))!.round(),
  );
  @override
  Future<void> play(String originalPath) =>
      _invoke<void>('play', {'path': originalPath});
  @override
  Future<void> stopPlayback() => _invoke<void>('stopPlayback');
  @override
  Future<AudioPlaybackSnapshot> playbackSnapshot() async {
    final value = await _map('playbackSnapshot');
    return AudioPlaybackSnapshot(
      isPlaying: value['isPlaying'] as bool,
      position: Duration(milliseconds: (value['positionMs'] as num).round()),
    );
  }
}
