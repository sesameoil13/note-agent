import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'audio_platform.dart';
import 'vault_storage.dart';

export 'audio_platform.dart';

enum RecordingPhase { idle, starting, recording, paused, saving, failed }

enum RecordingStatus {
  capturing,
  savePending,
  localSaved,
  exportFailed,
  interrupted,
  failed,
}

class WorkspaceRecording {
  const WorkspaceRecording({
    required this.id,
    required this.createdAt,
    required this.originalPath,
    required this.sourcePath,
    required this.duration,
    required this.byteLength,
    required this.status,
    this.error,
  });
  final String id;
  final DateTime createdAt;
  final String originalPath;
  final String sourcePath;
  final Duration duration;
  final int byteLength;
  final RecordingStatus status;
  final String? error;
  String get title => '录音';
  bool get canPlay =>
      byteLength > 0 &&
      status != RecordingStatus.capturing &&
      status != RecordingStatus.failed;
}

class RecordingState {
  const RecordingState({
    this.phase = RecordingPhase.idle,
    this.recordingId,
    this.duration = Duration.zero,
    this.levels = const [],
    this.error,
  });
  final RecordingPhase phase;
  final String? recordingId;
  final Duration duration;
  final List<double> levels;
  final String? error;
  bool get isActive =>
      phase == RecordingPhase.starting ||
      phase == RecordingPhase.recording ||
      phase == RecordingPhase.paused ||
      phase == RecordingPhase.saving;
}

class PlaybackState {
  const PlaybackState({
    this.recordingId,
    this.isPlaying = false,
    this.position = Duration.zero,
  });
  final String? recordingId;
  final bool isPlaying;
  final Duration position;
}

/// Internal recording state lives behind the NoteWorkspace public boundary.
class WorkspaceRecordings {
  WorkspaceRecordings(
    this.database,
    this.localDirectory,
    this.vault,
    this.audio,
    this.clock,
    this.createId,
  ) {
    database.execute('''CREATE TABLE IF NOT EXISTS recordings (
      id TEXT PRIMARY KEY, vault TEXT NOT NULL, created_at TEXT NOT NULL,
      original_path TEXT NOT NULL, source_path TEXT NOT NULL,
      duration_ms INTEGER NOT NULL DEFAULT 0, byte_length INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL, error TEXT
    )''');
  }
  static const maximumDuration = Duration(minutes: 10);
  static const maximumSyncBytes = 5000000;
  final Database database;
  final Directory localDirectory;
  final VaultStorage vault;
  final AudioPlatform? audio;
  final DateTime Function() clock;
  final String Function() createId;
  RecordingState state = const RecordingState();
  PlaybackState playback = const PlaybackState();
  bool _refreshing = false;
  bool _stopping = false;
  Timer? _timer;
  Future<void>? _backgroundRefresh;

  List<WorkspaceRecording> get recordings => List.unmodifiable(
    database
        .select(
          'SELECT * FROM recordings WHERE vault = ? ORDER BY created_at DESC, id DESC',
          [vault.identity],
        )
        .map(
          (row) => WorkspaceRecording(
            id: row['id'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
            originalPath: row['original_path'] as String,
            sourcePath: row['source_path'] as String,
            duration: Duration(milliseconds: row['duration_ms'] as int),
            byteLength: row['byte_length'] as int,
            status: RecordingStatus.values.byName(row['status'] as String),
            error: row['error'] as String?,
          ),
        ),
  );

  AudioPlatform get _audio => audio ?? (throw UnsupportedError('此平台尚未接入录音。'));

  Future<void> recover() async {
    for (final recording in recordings) {
      if (recording.status == RecordingStatus.savePending) {
        await export(recording.id);
      } else if (recording.status == RecordingStatus.capturing) {
        final file = File(recording.originalPath);
        final bytes = await file.exists() ? await file.length() : 0;
        database.execute(
          'UPDATE recordings SET status = ?, byte_length = ?, error = ? WHERE id = ?',
          [
            RecordingStatus.interrupted.name,
            bytes,
            '上次录音意外中断，已保留现有原文件；请尝试回放核对。',
            recording.id,
          ],
        );
      }
    }
  }

  Future<void> start() async {
    if (state.isActive) throw StateError('请先结束当前录音。');
    await stopPlayback();
    final id = createId();
    final original = File(p.join(localDirectory.path, 'recordings', '$id.m4a'));
    await original.parent.create(recursive: true);
    if (await original.exists()) throw StateError('录音身份已存在，请重新开始。');
    database.execute(
      '''INSERT INTO recordings
      (id, vault, created_at, original_path, source_path, status) VALUES (?, ?, ?, ?, ?, ?)''',
      [
        id,
        vault.identity,
        clock().toIso8601String(),
        original.path,
        vault.reference('attachments/note-agent/$id.m4a'),
        RecordingStatus.capturing.name,
      ],
    );
    state = RecordingState(phase: RecordingPhase.starting, recordingId: id);
    try {
      await _audio.startRecording(original.path);
      state = RecordingState(phase: RecordingPhase.recording, recordingId: id);
      _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        if (_backgroundRefresh != null) return;
        _backgroundRefresh = refresh()
            .catchError((Object error) {
              state = RecordingState(
                phase: state.phase,
                recordingId: state.recordingId,
                duration: state.duration,
                levels: state.levels,
                error: error.toString(),
              );
              _timer?.cancel();
            })
            .whenComplete(() => _backgroundRefresh = null);
      });
    } catch (error) {
      database.execute(
        'UPDATE recordings SET status = ?, error = ? WHERE id = ?',
        [RecordingStatus.failed.name, error.toString(), id],
      );
      state = RecordingState(
        phase: RecordingPhase.failed,
        recordingId: id,
        error: error.toString(),
      );
      rethrow;
    }
  }

  Future<void> pause() async {
    if (state.phase != RecordingPhase.recording) return;
    await _audio.pauseRecording();
    await refresh();
  }

  Future<void> resume() async {
    if (state.phase != RecordingPhase.paused) return;
    await _audio.resumeRecording();
    await refresh();
  }

  Future<void> refresh() async {
    if (_refreshing ||
        _stopping ||
        !state.isActive ||
        state.phase == RecordingPhase.starting) {
      return;
    }
    _refreshing = true;
    final recordingId = state.recordingId;
    try {
      final snapshot = await _audio.recordingSnapshot();
      if (_stopping || !state.isActive || state.recordingId != recordingId) {
        return;
      }
      final levels = [
        ...state.levels,
        snapshot.phase == AudioCapturePhase.recording
            ? snapshot.level.clamp(0.0, 1.0)
            : 0.0,
      ];
      state = RecordingState(
        phase: snapshot.phase == AudioCapturePhase.paused
            ? RecordingPhase.paused
            : RecordingPhase.recording,
        recordingId: state.recordingId,
        duration: snapshot.duration,
        levels: List.unmodifiable(
          levels.skip(levels.length > 64 ? levels.length - 64 : 0),
        ),
        error: snapshot.error,
      );
      if (snapshot.phase == AudioCapturePhase.stopped ||
          snapshot.duration >= maximumDuration) {
        await stop();
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<WorkspaceRecording> stop() async {
    final id = state.recordingId;
    if (id == null || !state.isActive || _stopping) {
      throw StateError('没有可结束的录音。');
    }
    _stopping = true;
    _timer?.cancel();
    _timer = null;
    state = RecordingState(
      phase: RecordingPhase.saving,
      recordingId: id,
      duration: state.duration,
      levels: state.levels,
    );
    try {
      final snapshot = await _audio.stopRecording();
      final recording = recordings.firstWhere((item) => item.id == id);
      final file = File(recording.originalPath);
      final length = await file.length();
      if (length == 0 || snapshot.error != null) {
        throw StateError(snapshot.error ?? '录音文件为空，请重试。');
      }
      final duration = await _audio.inspectRecording(file.path);
      if (duration <= Duration.zero) throw StateError('录音没有可回放的音频，现有文件已保留。');
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      database.execute(
        'UPDATE recordings SET status = ?, duration_ms = ?, byte_length = ?, error = NULL WHERE id = ?',
        [RecordingStatus.savePending.name, duration.inMilliseconds, length, id],
      );
      // The original is complete and durable before any vault publication.
      state = const RecordingState();
      return await export(id);
    } catch (error) {
      final original = File(
        recordings.firstWhere((item) => item.id == id).originalPath,
      );
      final bytes = await original.exists() ? await original.length() : 0;
      database.execute(
        'UPDATE recordings SET status = ?, error = ?, byte_length = ?, duration_ms = ? WHERE id = ? AND status = ?',
        [
          RecordingStatus.interrupted.name,
          error.toString(),
          bytes,
          state.duration.inMilliseconds,
          id,
          RecordingStatus.capturing.name,
        ],
      );
      state = RecordingState(
        phase: RecordingPhase.failed,
        recordingId: id,
        error: error.toString(),
      );
      rethrow;
    } finally {
      _stopping = false;
    }
  }

  Future<WorkspaceRecording> export(String id) async {
    final recording = recordings.firstWhere((item) => item.id == id);
    if (recording.status == RecordingStatus.capturing ||
        recording.status == RecordingStatus.failed ||
        recording.status == RecordingStatus.interrupted) {
      return recording;
    }
    try {
      if (recording.byteLength > maximumSyncBytes) {
        throw const FileSystemException('原音频已保留在本机，超过 5MB，尚未写入笔记库供同步。');
      }
      final storage = vault;
      if (storage is! BinaryVaultStorage) {
        throw const FileSystemException('原音频已保留在本机，此笔记库尚不支持音频写入。');
      }
      await (storage as BinaryVaultStorage).publishFile(
        vault.relativePath(recording.sourcePath),
        File(recording.originalPath),
        recording.id,
      );
      database.execute(
        'UPDATE recordings SET status = ?, error = NULL WHERE id = ?',
        [RecordingStatus.localSaved.name, id],
      );
    } on FileSystemException catch (error) {
      database.execute(
        'UPDATE recordings SET status = ?, error = ? WHERE id = ?',
        [RecordingStatus.exportFailed.name, error.message, id],
      );
    }
    return recordings.firstWhere((item) => item.id == id);
  }

  Future<void> play(String id) async {
    if (state.isActive) throw StateError('请先结束录音再回放。');
    final recording = recordings.firstWhere((item) => item.id == id);
    if (!recording.canPlay) throw StateError('此录音没有可回放的原音频。');
    await stopPlayback();
    await _audio.play(recording.originalPath);
    playback = PlaybackState(recordingId: id, isPlaying: true);
  }

  Future<void> refreshPlayback() async {
    if (playback.recordingId == null) return;
    final snapshot = await _audio.playbackSnapshot();
    playback = PlaybackState(
      recordingId: playback.recordingId,
      isPlaying: snapshot.isPlaying,
      position: snapshot.position,
    );
  }

  Future<void> stopPlayback() async {
    if (playback.recordingId != null) await _audio.stopPlayback();
    playback = const PlaybackState();
  }

  bool get needsClosing =>
      state.isActive ||
      _stopping ||
      _backgroundRefresh != null ||
      playback.recordingId != null;

  Future<void> close() async {
    _timer?.cancel();
    await _backgroundRefresh;
    if (state.isActive && state.phase != RecordingPhase.starting) await stop();
    await stopPlayback();
  }
}
