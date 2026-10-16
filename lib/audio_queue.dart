import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'audio_sources.dart';
import 'sync_policy.dart';
import 'vault_storage.dart';

export 'audio_sources.dart';

enum AudioProcessingStatus { pending, processing, failed, completed }

enum AudioOriginalStatus { importing, saved, incomplete }

enum AudioPublicationStatus { pending, published, exceedsFileLimit, failed }

class WorkspaceAudioSource {
  const WorkspaceAudioSource({
    required this.id,
    required this.submissionId,
    required this.outputNoteId,
    required this.originalName,
    required this.originalPath,
    required this.sourcePath,
    required this.createdAt,
    required this.originalStatus,
    required this.byteLength,
    required this.digest,
    required this.metadata,
    required this.processingStatus,
    required this.processingReason,
    required this.publicationStatus,
    required this.publicationError,
    required this.attempts,
    required this.automaticRetries,
    required this.nextAttemptAt,
    required this.transcript,
    required this.stage,
  });
  final String id,
      submissionId,
      outputNoteId,
      originalName,
      originalPath,
      sourcePath;
  final DateTime createdAt;
  final AudioOriginalStatus originalStatus;
  final int byteLength, attempts, automaticRetries;
  final String? digest, processingReason, publicationError, transcript;
  final String stage;
  final AudioSourceMetadata? metadata;
  final AudioProcessingStatus processingStatus;
  final AudioPublicationStatus publicationStatus;
  final DateTime? nextAttemptAt;
  bool get originalSaved => originalStatus == AudioOriginalStatus.saved;
  bool get canRetryProcessing =>
      originalSaved &&
      (metadata != null || stage == 'inspectionFailedRetryable');
}

/// No processor is installed in production yet. A future paid adapter must
/// reserve/settle budget itself, classify ambiguous outcomes, and must not
/// declare interrupted paid requests safe to replay without reconciliation.
abstract interface class AudioProcessor {
  bool get canReplayInterruptedRequests;
  Future<AudioTranscript> transcribe(AudioProcessingRequest request);
  Future<AudioOrganizedNote> organize(
    AudioProcessingRequest request,
    AudioTranscript transcript,
  );
}

class AudioProcessingRequest {
  const AudioProcessingRequest({
    required this.sourceId,
    required this.attemptId,
    required this.original,
    required this.digest,
    required this.metadata,
  });
  final String sourceId, attemptId, digest;
  final File original;
  final AudioSourceMetadata metadata;
}

class AudioTranscript {
  const AudioTranscript(this.text);
  final String text;
}

class AudioOrganizedNote {
  const AudioOrganizedNote({required this.title, required this.text});
  final String title, text;
}

enum AudioProcessingFailureKind {
  recoverable,
  credentials,
  balance,
  budget,
  outcomeUnknown,
  unsupported,
  invalidResult,
}

class AudioProcessingFailure implements Exception {
  const AudioProcessingFailure(this.kind, this.message);
  final AudioProcessingFailureKind kind;
  final String message;
  @override
  String toString() => message;
}

typedef AudioQueueCommit = Future<T> Function<T>(Future<T> Function() action);
typedef AudioNoteMaterializer = Future<void> Function(
  WorkspaceAudioSource source,
  AudioOrganizedNote note,
);

/// Internal durable source/queue state; exposed exclusively via NoteWorkspace.
class WorkspaceAudioQueue {
  WorkspaceAudioQueue(
    this.database,
    this.local,
    this.vault,
    this.inspector,
    this.clock,
    this.createId,
    this.processor,
  ) {
    database.execute('''CREATE TABLE IF NOT EXISTS audio_queue (
      id TEXT PRIMARY KEY, vault TEXT NOT NULL, submission_id TEXT NOT NULL,
      output_note_id TEXT NOT NULL, original_name TEXT NOT NULL, original_path TEXT NOT NULL,
      source_path TEXT NOT NULL, created_at TEXT NOT NULL, original_status TEXT NOT NULL,
      byte_length INTEGER NOT NULL DEFAULT 0, digest TEXT, metadata TEXT,
      processing_status TEXT NOT NULL, processing_reason TEXT,
      publication_status TEXT NOT NULL, publication_error TEXT,
      stage TEXT NOT NULL DEFAULT 'inspect', attempts INTEGER NOT NULL DEFAULT 0,
      automatic_retries INTEGER NOT NULL DEFAULT 0, next_attempt_at TEXT,
      transcript TEXT, organized TEXT, attempt_id TEXT, failure_kind TEXT, replay_safe INTEGER NOT NULL DEFAULT 0,
      UNIQUE(vault, submission_id)
    )''');
  }
  final Database database;
  final Directory local;
  final VaultStorage vault;
  final AudioSourceInspector inspector;
  final DateTime Function() clock;
  final String Function() createId;
  final AudioProcessor? processor;
  Future<void>? _worker;
  Timer? _retryTimer;
  bool _stopped = false;
  static const maximumInspectionBytes = 256 * 1024 * 1024;
  List<WorkspaceAudioSource> get sources => List.unmodifiable(
    database
        .select(
          'SELECT * FROM audio_queue WHERE vault = ? ORDER BY created_at DESC, id DESC',
          [vault.identity],
        )
        .map(
          (row) => WorkspaceAudioSource(
            id: row['id'] as String,
            submissionId: row['submission_id'] as String,
            outputNoteId: row['output_note_id'] as String,
            originalName: row['original_name'] as String,
            originalPath: row['original_path'] as String,
            sourcePath: row['source_path'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
            originalStatus: AudioOriginalStatus.values.byName(
              row['original_status'] as String,
            ),
            byteLength: row['byte_length'] as int,
            digest: row['digest'] as String?,
            metadata: row['metadata'] == null
                ? null
                : AudioSourceMetadata.fromJson(
                    jsonDecode(row['metadata'] as String)
                        as Map<String, dynamic>,
                  ),
            processingStatus: AudioProcessingStatus.values.byName(
              row['processing_status'] as String,
            ),
            processingReason: row['processing_reason'] as String?,
            publicationStatus: AudioPublicationStatus.values.byName(
              row['publication_status'] as String,
            ),
            publicationError: row['publication_error'] as String?,
            attempts: row['attempts'] as int,
            automaticRetries: row['automatic_retries'] as int,
            nextAttemptAt: row['next_attempt_at'] == null
                ? null
                : DateTime.parse(row['next_attempt_at'] as String),
            transcript: row['transcript'] as String?,
            stage: row['stage'] as String,
          ),
        ),
  );
  WorkspaceAudioSource source(String id) =>
      sources.firstWhere((item) => item.id == id);
  Row row(String id) => database.select(
    'SELECT * FROM audio_queue WHERE id = ? AND vault = ?',
    [id, vault.identity],
  ).single;

  Future<({String digest, int bytes})> _hash(File file, {File? copy}) async {
    final sink = const DartSha256().newHashSink();
    final output = copy == null ? null : await copy.open(mode: FileMode.write);
    var bytes = 0;
    try {
      await for (final chunk in file.openRead()) {
        sink.add(chunk);
        bytes += chunk.length;
        if (output != null) await output.writeFrom(chunk);
      }
      if (output != null) await output.flush();
      sink.close();
      final digest = await sink.hash();
      return (
        digest: digest.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        bytes: bytes,
      );
    } finally {
      await output?.close();
    }
  }

  Future<WorkspaceAudioSource> import(
    File original,
    String submissionId,
  ) async {
    if (submissionId.trim().isEmpty || submissionId.length > 200) {
      throw ArgumentError('缺少有效的导入身份。');
    }
    final existing = sources
        .where((s) => s.submissionId == submissionId)
        .firstOrNull;
    if (existing?.digest != null) {
      final input = await _hash(original);
      if (input.digest != existing!.digest ||
          input.bytes != existing.byteLength) {
        throw ArgumentError('此提交身份已用于不同的原件，请作为新录音导入。');
      }
      if (existing.originalSaved) return existing;
    }
    final id = existing?.id ?? createId();
    var name =
        existing?.originalName ??
        p
            .basename(original.path)
            .replaceAll(RegExp(r'[\x00-\x1f\[\]()\\/:*?"<>|]'), '_');
    if (name.isEmpty || name == '.' || name == '..') name = '原音频';
    if (name.length > 180) name = name.substring(name.length - 180);
    final destination = File(
      existing?.originalPath ?? p.join(local.path, 'audio-sources', id, name),
    );
    if (existing == null) {
      database.execute(
        '''INSERT INTO audio_queue
        (id,vault,submission_id,output_note_id,original_name,original_path,source_path,created_at,
        original_status,processing_status,processing_reason,publication_status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)''',
        [
          id,
          vault.identity,
          submissionId,
          '$id-note',
          name,
          destination.path,
          vault.reference('attachments/note-agent/$id/$name'),
          clock().toIso8601String(),
          AudioOriginalStatus.importing.name,
          AudioProcessingStatus.pending.name,
          '正在保存原件',
          AudioPublicationStatus.pending.name,
        ],
      );
    }
    try {
      await destination.parent.create(recursive: true);
      final staging = File('${destination.path}.pending');
      final copied = await _hash(original, copy: staging);
      if (existing?.digest != null && copied.digest != existing!.digest) {
        throw ArgumentError('原件在复制期间发生变化，请重新选择。');
      }
      // Journal both checksum and complete staging before the atomic rename.
      database.execute(
        'UPDATE audio_queue SET digest = ?, byte_length = ?, original_status = ? WHERE id = ?',
        [copied.digest, copied.bytes, AudioOriginalStatus.importing.name, id],
      );
      await staging.rename(destination.path);
      await _validate(id);
      await publish(id);
    } on FileSystemException catch (error) {
      database.execute(
        'UPDATE audio_queue SET original_status = ?, processing_status = ?, processing_reason = ? WHERE id = ?',
        [
          AudioOriginalStatus.incomplete.name,
          AudioProcessingStatus.failed.name,
          '原件尚未完整保存，请重新选择同一文件重试：${error.message}',
          id,
        ],
      );
    }
    return source(id);
  }

  Future<void> adoptRecording({
    required String id,
    required File original,
    required String sourcePath,
    required DateTime createdAt,
  }) async {
    if (sources.any((s) => s.id == id)) return;
    final actual = await _hash(original);
    database.execute(
      '''INSERT INTO audio_queue
      (id,vault,submission_id,output_note_id,original_name,original_path,source_path,created_at,
       original_status,byte_length,digest,processing_status,publication_status)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        id,
        vault.identity,
        'capture:$id',
        '$id-note',
        p.basename(original.path),
        original.path,
        sourcePath,
        createdAt.toIso8601String(),
        AudioOriginalStatus.saved.name,
        actual.bytes,
        actual.digest,
        AudioProcessingStatus.pending.name,
        AudioPublicationStatus.pending.name,
      ],
    );
    await _validate(id);
    await publish(id);
    if (processor == null) markDisconnected();
  }

  Future<void> _validate(String id) async {
    final item = source(id);
    database.execute(
      'UPDATE audio_queue SET original_status = ? WHERE id = ?',
      [AudioOriginalStatus.saved.name, id],
    );
    try {
      if (item.byteLength > maximumInspectionBytes) {
        throw const AudioInspectionFailure('原件已保存；超过本机 256 MB 检查上限，尚未进入处理。');
      }
      final metadata = await inspector
          .inspectAudioSource(item.originalPath)
          .timeout(const Duration(seconds: 10));
      if (metadata.duration <= Duration.zero ||
          metadata.duration > const Duration(hours: 24) ||
          metadata.sampleRate < 8000 ||
          metadata.sampleRate > 384000 ||
          metadata.channels < 1 ||
          metadata.channels > 32 ||
          metadata.container.isEmpty ||
          metadata.codec.isEmpty) {
        throw const AudioInspectionFailure('音频时长或参数超出本机处理范围，原件已保留。');
      }
      database.execute(
        "UPDATE audio_queue SET metadata = ?, processing_status = ?, processing_reason = NULL, failure_kind = NULL, stage = 'transcribe' WHERE id = ?",
        [jsonEncode(metadata.toJson()), AudioProcessingStatus.pending.name, id],
      );
    } catch (error) {
      database.execute(
        "UPDATE audio_queue SET processing_status = ?, processing_reason = ?, failure_kind = ?, stage = ? WHERE id = ?",
        [
          AudioProcessingStatus.failed.name,
          error is TimeoutException ? '检查音频超时，原件已保留；可手动重试。' : error.toString(),
          error is TimeoutException ||
                  error is AudioInspectionFailure && error.retryable
              ? 'inspectionRetryable'
              : 'unsupported',
          error is TimeoutException ||
                  error is AudioInspectionFailure && error.retryable
              ? 'inspectionFailedRetryable'
              : 'inspectionFailed',
          id,
        ],
      );
    }
  }

  Future<void> publish(String id) async {
    final item = source(id);
    if (!item.originalSaved) return;
    if (item.byteLength > ObsidianSyncStandard.maximumFileBytes) {
      database.execute(
        'UPDATE audio_queue SET publication_status = ?, publication_error = ? WHERE id = ?',
        [
          AudioPublicationStatus.exceedsFileLimit.name,
          '超过 Standard 单文件 5 MB；原件保留在本机，未同步。',
          id,
        ],
      );
      return;
    }
    try {
      final storage = vault;
      if (storage is! BinaryVaultStorage) {
        throw const FileSystemException('此笔记库尚不支持原音频写入，原件已保留。');
      }
      await (storage as BinaryVaultStorage).publishFile(
        vault.relativePath(item.sourcePath),
        File(item.originalPath),
        item.id,
      );
      database.execute(
        'UPDATE audio_queue SET publication_status = ?, publication_error = NULL WHERE id = ?',
        [AudioPublicationStatus.published.name, id],
      );
    } on FileSystemException catch (error) {
      database.execute(
        'UPDATE audio_queue SET publication_status = ?, publication_error = ? WHERE id = ?',
        [AudioPublicationStatus.failed.name, error.message, id],
      );
    }
  }

  Future<void> recover() async {
    _interruptRunning();
    for (final item in sources) {
      if (item.originalStatus != AudioOriginalStatus.saved) {
        final finalFile = File(item.originalPath);
        final staging = File('${item.originalPath}.pending');
        final candidate = await finalFile.exists() ? finalFile : staging;
        if (item.digest != null && await candidate.exists()) {
          final data = await _hash(candidate);
          if (data.digest == item.digest && data.bytes == item.byteLength) {
            if (candidate.path != finalFile.path) {
              await candidate.rename(finalFile.path);
            }
            await _validate(item.id);
          }
        }
        if (!source(item.id).originalSaved) {
          database.execute(
            'UPDATE audio_queue SET original_status = ?, processing_status = ?, processing_reason = ? WHERE id = ?',
            [
              AudioOriginalStatus.incomplete.name,
              AudioProcessingStatus.failed.name,
              '导入意外中断，原件尚未完整保存；请重新选择同一文件。',
              item.id,
            ],
          );
        }
      }
      var current = source(item.id);
      if (current.originalSaved) {
        try {
          final actual = await _hash(File(current.originalPath));
          if (actual.digest != current.digest ||
              actual.bytes != current.byteLength) {
            throw const FileSystemException('原件校验不符');
          }
          if (current.stage == 'inspect') await _validate(current.id);
        } on FileSystemException {
          database.execute(
            'UPDATE audio_queue SET original_status = ?, processing_status = ?, processing_reason = ? WHERE id = ?',
            [
              AudioOriginalStatus.incomplete.name,
              AudioProcessingStatus.failed.name,
              '本机原件缺失或校验不符，请重新选择同一文件恢复。',
              current.id,
            ],
          );
        }
      }
      current = source(item.id);
      if (current.publicationStatus == AudioPublicationStatus.pending) {
        await publish(item.id);
      }
    }
  }

  void _interruptRunning() {
    for (final item in sources.where(
      (s) => s.processingStatus == AudioProcessingStatus.processing,
    )) {
      final uncertain =
          item.stage != 'materialize' && row(item.id)['replay_safe'] != 1;
      database.execute(
        'UPDATE audio_queue SET processing_status = ?, processing_reason = ?, attempt_id = NULL, failure_kind = ? WHERE id = ?',
        [
          (uncertain
                  ? AudioProcessingStatus.failed
                  : AudioProcessingStatus.pending)
              .name,
          uncertain ? '上次请求结果未确认；请核对服务与预算后手动重试。' : '上次处理意外中断，等待恢复。',
          uncertain ? AudioProcessingFailureKind.outcomeUnknown.name : null,
          item.id,
        ],
      );
    }
  }

  Future<void> retry(String id) async {
    final item = source(id);
    if (item.processingStatus == AudioProcessingStatus.completed ||
        item.processingStatus == AudioProcessingStatus.processing) {
      return;
    }
    final kind = row(id)['failure_kind'];
    if (!item.originalSaved) throw StateError('原件尚未完整保存，请重新选择同一文件。');
    if (item.metadata == null) {
      if (kind == 'inspectionRetryable') {
        await _validate(id);
      } else {
        return;
      }
    } else {
      database.execute(
        'UPDATE audio_queue SET processing_status = ?, processing_reason = NULL, next_attempt_at = NULL, automatic_retries = 0, failure_kind = NULL WHERE id = ?',
        [AudioProcessingStatus.pending.name, id],
      );
    }
  }

  Future<void> run(AudioQueueCommit commit, AudioNoteMaterializer materialize) {
    if (_stopped) return Future.value();
    if (_worker != null) return _worker!;
    _retryTimer?.cancel();
    return _worker = _drain(commit, materialize).whenComplete(() {
      _worker = null;
      if (!_stopped) _schedule(commit, materialize);
    });
  }

  bool _current(String id, String attemptId) =>
      !_stopped && row(id)['attempt_id'] == attemptId;

  Future<void> _drain(
    AudioQueueCommit commit,
    AudioNoteMaterializer materialize,
  ) async {
    while (!_stopped) {
      final item = await commit(() async {
        final candidate = sources
            .where(
              (s) =>
                  s.originalSaved &&
                  s.metadata != null &&
                  s.processingStatus == AudioProcessingStatus.pending &&
                  (s.nextAttemptAt == null ||
                      !s.nextAttemptAt!.isAfter(clock())),
            )
            .where((s) => processor != null || s.stage == 'materialize')
            .firstOrNull;
        if (candidate == null) {
          if (processor == null) markDisconnected();
          return null;
        }
        final attempt = '${candidate.id}-${candidate.attempts + 1}';
        database.execute(
          'UPDATE audio_queue SET processing_status = ?, processing_reason = NULL, attempt_id = ?, replay_safe = ?, attempts = attempts + 1, next_attempt_at = NULL WHERE id = ?',
          [
            AudioProcessingStatus.processing.name,
            attempt,
            processor?.canReplayInterruptedRequests == true ? 1 : 0,
            candidate.id,
          ],
        );
        return (source: source(candidate.id), attempt: attempt);
      });
      if (item == null || _stopped) break;
      final id = item.source.id;
      final attempt = item.attempt;
      try {
        final original = File(item.source.originalPath);
        final actual = await _hash(original);
        if (_stopped) break;
        if (actual.digest != item.source.digest ||
            actual.bytes != item.source.byteLength) {
          throw const AudioProcessingFailure(
            AudioProcessingFailureKind.unsupported,
            '原件校验不符，已停止处理；请重新选择原文件。',
          );
        }
        final request = AudioProcessingRequest(
          sourceId: id,
          attemptId: attempt,
          original: original,
          digest: actual.digest,
          metadata: item.source.metadata!,
        );
        var data = await commit<Map<String, Object?>?>(
          () async =>
              _current(id, attempt) ? Map<String, Object?>.from(row(id)) : null,
        );
        if (data == null || _stopped) break;
        if (data['transcript'] == null) {
          final transcript = await processor!.transcribe(request);
          if (_stopped) break;
          if (transcript.text.trim().isEmpty ||
              utf8.encode(transcript.text).length > 4000000) {
            throw const AudioProcessingFailure(
              AudioProcessingFailureKind.invalidResult,
              '转写结果为空或超过本机保存范围，原件已保留。',
            );
          }
          await commit(() async {
            if (_current(id, attempt)) {
              database.execute(
                'UPDATE audio_queue SET transcript = ?, stage = ? WHERE id = ?',
                [transcript.text, 'organize', id],
              );
            }
          });
        }
        data = await commit<Map<String, Object?>?>(
          () async =>
              _current(id, attempt) ? Map<String, Object?>.from(row(id)) : null,
        );
        if (data == null || _stopped) break;
        if (data['organized'] == null) {
          final organized = await processor!.organize(
            request,
            AudioTranscript(data['transcript'] as String),
          );
          if (_stopped) break;
          if (organized.title.trim().isEmpty ||
              organized.title.length > 200 ||
              organized.text.trim().isEmpty ||
              utf8.encode(organized.text).length > 4000000) {
            throw const AudioProcessingFailure(
              AudioProcessingFailureKind.invalidResult,
              '整理结果无效，完整转写与原件已保留。',
            );
          }
          await commit(() async {
            if (_current(id, attempt)) {
              database.execute(
                'UPDATE audio_queue SET organized = ?, stage = ? WHERE id = ?',
                [
                  jsonEncode({
                    'title': organized.title,
                    'text': organized.text,
                  }),
                  'materialize',
                  id,
                ],
              );
            }
          });
        }
        await commit(() async {
          if (!_current(id, attempt)) return;
          final organized = jsonDecode(
            row(id)['organized'] as String,
          ) as Map<String, dynamic>;
          await materialize(
            source(id),
            AudioOrganizedNote(
              title: organized['title'] as String,
              text: organized['text'] as String,
            ),
          );
          if (_current(id, attempt)) {
            database.execute(
              'UPDATE audio_queue SET processing_status = ?, processing_reason = NULL, attempt_id = NULL, failure_kind = NULL WHERE id = ?',
              [AudioProcessingStatus.completed.name, id],
            );
          }
        });
      } catch (error) {
        if (_stopped) break;
        await commit(() async {
          if (!_current(id, attempt)) return;
          final failure = error is AudioProcessingFailure
              ? error
              : error is FileSystemException
              ? const AudioProcessingFailure(
                  AudioProcessingFailureKind.unsupported,
                  '原音频无法读取，请检查本机原件后重试。',
                )
              : const AudioProcessingFailure(
                  AudioProcessingFailureKind.recoverable,
                  '处理暂时未完成，原件已保留。',
                );
          final current = source(id);
          final canRetry =
              failure.kind == AudioProcessingFailureKind.recoverable &&
              current.automaticRetries < 3;
          final retries = current.automaticRetries + (canRetry ? 1 : 0);
          final next = canRetry
              ? clock().add(Duration(seconds: 5 * (1 << (retries - 1))))
              : null;
          database.execute(
            'UPDATE audio_queue SET processing_status = ?, processing_reason = ?, failure_kind = ?, automatic_retries = ?, next_attempt_at = ?, attempt_id = NULL WHERE id = ?',
            [
              (canRetry
                      ? AudioProcessingStatus.pending
                      : AudioProcessingStatus.failed)
                  .name,
              failure.message,
              failure.kind.name,
              retries,
              next?.toIso8601String(),
              id,
            ],
          );
        });
      }
    }
  }

  void _schedule(AudioQueueCommit commit, AudioNoteMaterializer materialize) {
    if (processor == null) return;
    final dates =
        sources
            .where(
              (s) =>
                  s.processingStatus == AudioProcessingStatus.pending &&
                  s.nextAttemptAt != null,
            )
            .map((s) => s.nextAttemptAt!)
            .toList()
          ..sort();
    if (dates.isEmpty) return;
    final delay = dates.first.difference(clock());
    _retryTimer = Timer(
      delay < const Duration(seconds: 1) ? const Duration(seconds: 1) : delay,
      () {
        if (!_stopped) unawaited(run(commit, materialize));
      },
    );
  }

  void stop() {
    if (_stopped) return;
    _retryTimer?.cancel();
    _interruptRunning();
    _stopped = true;
  }

  void markDisconnected() {
    database.execute(
      'UPDATE audio_queue SET processing_reason = ? WHERE vault = ? AND processing_status = ? AND next_attempt_at IS NULL AND metadata IS NOT NULL',
      [
        '处理服务未连接；原音频已保存，待处理。',
        vault.identity,
        AudioProcessingStatus.pending.name,
      ],
    );
  }
}
