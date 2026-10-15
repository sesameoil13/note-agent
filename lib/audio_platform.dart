/// Operating-system microphone and player boundary. No network or AI is used.
abstract interface class AudioPlatform {
  Future<void> startRecording(String originalPath);
  Future<void> pauseRecording();
  Future<void> resumeRecording();
  Future<AudioCaptureSnapshot> recordingSnapshot();
  Future<AudioCaptureSnapshot> stopRecording();
  Future<Duration> inspectRecording(String originalPath);
  Future<void> play(String originalPath);
  Future<void> stopPlayback();
  Future<AudioPlaybackSnapshot> playbackSnapshot();
}

enum AudioCapturePhase { recording, paused, stopped }

class AudioCaptureSnapshot {
  const AudioCaptureSnapshot({
    required this.phase,
    required this.duration,
    this.level = 0,
    this.error,
  });
  final AudioCapturePhase phase;
  final Duration duration;
  final double level;
  final String? error;
}

class AudioPlaybackSnapshot {
  const AudioPlaybackSnapshot({
    required this.isPlaying,
    required this.position,
  });
  final bool isPlaying;
  final Duration position;
}
