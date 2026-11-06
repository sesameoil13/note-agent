part of 'note_workspace.dart';

enum ProcessingFailureSource { text, audio, document }

/// The next step for a failed item. None of them re-runs a stage whose
/// result was already saved.
enum ProcessingRecovery {
  /// 重试: the item is tried again.
  retry,

  /// The original was never completely retained; the file must be chosen again.
  reselectOriginal,
}

class WorkspaceProcessingFailure {
  const WorkspaceProcessingFailure({
    required this.id,
    required this.source,
    required this.title,
    required this.message,
    required this.recovery,
    this.noteId,
    this.automaticRetriesUsed = 0,
  });
  final String id, title, message;
  final ProcessingFailureSource source;
  final ProcessingRecovery recovery;
  final String? noteId;
  final int automaticRetriesUsed;
}

extension _WorkspaceProcessingRecovery on NoteWorkspace {
  List<WorkspaceProcessingFailure> _processingFailures() {
    final failures = <WorkspaceProcessingFailure>[];
    String titleOf(String? noteId, String fallback) =>
        notes.where((n) => n.id == noteId).firstOrNull?.title ?? fallback;
    for (final job in textJobs) {
      final p = _textPayload(job.id);
      // Only automatic 整理 is retried; an old estimate/confirm job (or the
      // organizing step of an old recording job) never is.
      if (job.status != TextProcessingStatus.failed ||
          p['automatic'] != true) {
        continue;
      }
      final audio = _audioQueue.sources
          .where((s) => s.id == p['audio'])
          .firstOrNull;
      failures.add(
        WorkspaceProcessingFailure(
          id: 'text:${job.id}',
          source: ProcessingFailureSource.text,
          noteId: job.noteId,
          title: titleOf(job.noteId, audio?.originalName ?? '文字笔记'),
          message: job.message,
          recovery: ProcessingRecovery.retry,
          automaticRetriesUsed: p['autoRetries'] as int? ?? 0,
        ),
      );
    }
    // Old estimate/confirm jobs, finished or dropped on upgrade, are never
    // sent again.
    final oldJobSources = {
      for (final row in _database.select(
        'SELECT source_id FROM audio_jobs WHERE vault=?',
        [vaultStorage.identity],
      ))
        row['source_id'] as String,
    };
    for (final source in _audioQueue.sources) {
      if (oldJobSources.contains(source.id)) continue;
      if (source.processingStatus != AudioProcessingStatus.failed &&
          source.originalStatus != AudioOriginalStatus.incomplete) {
        continue;
      }
      failures.add(
        WorkspaceProcessingFailure(
          id: 'audio:${source.id}',
          source: ProcessingFailureSource.audio,
          noteId: source.outputNoteId,
          title: titleOf(source.outputNoteId, source.originalName),
          message: source.processingReason ?? '原件尚未完整保存，请重新选择文件。',
          recovery: !source.originalSaved
              ? ProcessingRecovery.reselectOriginal
              : ProcessingRecovery.retry,
        ),
      );
    }
    for (final note in notes) {
      final doc = note.document;
      if (doc == null ||
          _activeDocuments.containsKey(note.id) ||
          _retryingDocuments.contains(note.id)) {
        continue;
      }
      final failed =
          [
            DocumentImportStatus.interrupted,
            DocumentImportStatus.originalFailed,
            DocumentImportStatus.writePending,
          ].contains(doc.status) ||
          (doc.status == DocumentImportStatus.ready &&
              doc.result?.completion == DocumentCompletion.failed);
      if (!failed) continue;
      failures.add(
        WorkspaceProcessingFailure(
          id: 'document:${note.id}',
          source: ProcessingFailureSource.document,
          noteId: note.id,
          title: note.title,
          message:
              doc.error ??
              doc.result?.problems.firstOrNull?.message ??
              '文档提取未完成，原件保留。',
          recovery: doc.attachmentId == null
              ? ProcessingRecovery.reselectOriginal
              : ProcessingRecovery.retry,
        ),
      );
    }
    return List.unmodifiable(failures);
  }

  Future<void> _recoverFailure(String id, File? original) async {
    final failure = _processingFailures().where((f) => f.id == id).firstOrNull;
    if (failure == null) throw StateError('此失败项已处理或不存在。');
    final key = id.substring(id.indexOf(':') + 1);
    switch (failure.source) {
      case ProcessingFailureSource.text:
        await retryTextProcessing(key);
      case ProcessingFailureSource.audio:
        if (failure.recovery == ProcessingRecovery.reselectOriginal) {
          throw StateError('原件尚未完整保存，请重新选择同一录音文件导入。');
        }
        await retryAudioCheck(key);
      case ProcessingFailureSource.document:
        await retryDocumentExtraction(key, original: original);
    }
  }
}
