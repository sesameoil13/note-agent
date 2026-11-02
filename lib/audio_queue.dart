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

/// The audio's own check: [pending] until it passes and is organized,
/// [failed] when refused or its original is incomplete, [completed] once
/// organized. Transcription and 整理 show as `OrganizeStatus`.
/// [processing] is only found in rows of versions before automatic 整理.
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
  final int byteLength;
  final String? digest, processingReason, publicationError, transcript;
  final String stage;

  final AudioSourceMetadata? metadata;
  final AudioProcessingStatus processingStatus;

  /// Recordings are adopted under this submission prefix; imports never are.
  static const recordingSubmissionPrefix = 'capture:';
  bool get isRecording => submissionId.startsWith(recordingSubmissionPrefix);
  final AudioPublicationStatus publicationStatus;
  bool get originalSaved => originalStatus == AudioOriginalStatus.saved;
  /// Whether its failed check may pass on a second try (e.g. a timeout).
  bool get canRetryCheck =>
      originalSaved && stage == 'inspectionFailedRetryable';
}

/// Internal durable source/queue state; exposed exclusively via NoteWorkspace.
class WorkspaceAudioQueue {
  WorkspaceAudioQueue(
    this.database,
    this.local,
    this.vault,
    this.inspector,
    this.clock,
    this.createId,
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
    // Set on audio captured since 整理 became automatic (ADR 0004); audio
    // from an older version is never queued by itself.
    if (!database
        .select('PRAGMA table_info(audio_queue)')
        .any((row) => row['name'] == 'automatic')) {
      database.execute(
        'ALTER TABLE audio_queue ADD COLUMN automatic INTEGER NOT NULL DEFAULT 0',
      );
    }
  }
  final Database database;
  final Directory local;
  final VaultStorage vault;
  final AudioSourceInspector inspector;
  final DateTime Function() clock;
  final String Function() createId;
  static const maximumInspectionBytes = 256 * 1024 * 1024;
  /// Bailian transcribes at most 5 minutes per request (ADR 0003, 0004).
  static const maximumImportDuration = Duration(minutes: 5);
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
            transcript: row['transcript'] as String?,
            stage: row['stage'] as String,
          ),
        ),
  );
  WorkspaceAudioSource source(String id) =>
      sources.firstWhere((item) => item.id == id);

  /// Ids of audio captured for automatic 整理 that passed its check.
  List<String> checkedAutomaticIds() => [
    for (final row in database.select(
      'SELECT id FROM audio_queue WHERE vault = ? AND automatic = 1 AND metadata IS NOT NULL ORDER BY created_at, id',
      [vault.identity],
    ))
      row['id'] as String,
  ];
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
        original_status,processing_status,processing_reason,publication_status,automatic)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1)''',
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
       original_status,byte_length,digest,processing_status,publication_status,automatic)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1)''',
      [
        id,
        vault.identity,
        '${WorkspaceAudioSource.recordingSubmissionPrefix}$id',
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
      if (metadata.duration.inMilliseconds < 1 ||
          metadata.duration > const Duration(hours: 24) ||
          metadata.sampleRate < 8000 ||
          metadata.sampleRate > 384000 ||
          metadata.channels < 1 ||
          metadata.channels > 32 ||
          metadata.container.isEmpty ||
          metadata.codec.isEmpty) {
        throw const AudioInspectionFailure('音频时长或参数超出本机处理范围，原件已保留。');
      }
      // Recordings are capped by the recorder; their encoded length may run a
      // few milliseconds past it, so only imported audio is held to the limit.
      if (!item.isRecording && metadata.duration > maximumImportDuration) {
        throw const AudioInspectionFailure('导入音频超过 5 分钟，未发送；原件已保留。');
      }
      database.execute(
        "UPDATE audio_queue SET metadata = ?, processing_status = ?, processing_reason = NULL, failure_kind = NULL, stage = 'checked' WHERE id = ?",
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

  /// Checks again audio whose check failed for a reason that may pass on
  /// a second try (e.g. a timeout). A refused one (e.g. longer than five
  /// minutes) stays refused.
  Future<void> retry(String id) async {
    final item = source(id);
    if (!item.originalSaved) throw StateError('原件尚未完整保存，请重新选择同一文件。');
    if (item.metadata == null &&
        row(id)['failure_kind'] == 'inspectionRetryable') {
      await _validate(id);
    }
  }
}
