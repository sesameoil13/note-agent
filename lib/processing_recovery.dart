part of 'note_workspace.dart';

enum ProcessingFailureSource { text, audio, document }

/// The next safe step for a failed item. None of them re-runs a stage whose
/// result was already saved, and none releases a possibly charged hold.
enum ProcessingRecovery {
  /// A bounded automatic retry is still scheduled; nothing to do yet.
  automaticRetryScheduled,

  /// Manual retry: a fresh, separately admitted attempt (may be charged).
  retry,

  /// A new attempt is estimated and reserved; recovering again sends it.
  confirmPrepared,

  /// A paid stage's charge must be reconciled before the next stage starts.
  reconcileCost,

  /// The complete transcript is kept; only organization is estimated again.
  reorganizeOnly,

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
    this.nextAutomaticRetryAt,
    this.needsAccountAction = false,
    this.estimatedCnyMicros = 0,
  });
  final String id, title, message;
  final ProcessingFailureSource source;
  final ProcessingRecovery recovery;
  final String? noteId;
  final int automaticRetriesUsed, estimatedCnyMicros;
  final DateTime? nextAutomaticRetryAt;

  /// Credentials, balance or budget: never retried automatically. The user
  /// fixes the account first; a later manual retry is still allowed.
  final bool needsAccountAction;
}

const _accountFailureKinds = {
  'credentials',
  'balance',
  'budget',
  'budget_exceeded',
};

extension _WorkspaceProcessingRecovery on NoteWorkspace {
  List<WorkspaceProcessingFailure> _processingFailures() {
    final failures = <WorkspaceProcessingFailure>[];
    String titleOf(String? noteId, String fallback) =>
        notes.where((n) => n.id == noteId).firstOrNull?.title ?? fallback;
    for (final job in textJobs) {
      final p = _textPayload(job.id);
      if (p['audioPipeline'] is String || p['reorganize'] == true) continue;
      final kind = p['failureKind'] as String?;
      final recovery = switch (job.status) {
        TextProcessingStatus.failed => ProcessingRecovery.retry,
        TextProcessingStatus.costPending when job.canRetry =>
          ProcessingRecovery.retry,
        TextProcessingStatus.review
            when p['result'] == null && p['validationError'] is String =>
          ProcessingRecovery.retry,
        TextProcessingStatus.prepared when kind != null =>
          ProcessingRecovery.confirmPrepared,
        _ => null,
      };
      if (recovery == null) continue;
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
          recovery: recovery,
          automaticRetriesUsed: p['autoRetries'] as int? ?? 0,
          needsAccountAction: _accountFailureKinds.contains(kind),
          estimatedCnyMicros: job.estimatedCnyMicros,
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
              : source.nextAttemptAt != null
              ? ProcessingRecovery.automaticRetryScheduled
              : ProcessingRecovery.retry,
          automaticRetriesUsed: source.automaticRetries,
          nextAutomaticRetryAt: source.nextAttemptAt,
          needsAccountAction: _accountFailureKinds.contains(source.failureKind),
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
        await retryAudioProcessing(key);
      case ProcessingFailureSource.document:
        await retryDocumentExtraction(key, original: original);
    }
  }

  /// (attempt, label, text job or null) of requests that may have been billed
  /// and have no receipt, for the failure [failureId].
  List<(String, String, String?)> _chargeCandidates(String failureId) {
    final key = failureId.substring(failureId.indexOf(':') + 1);
    final out = <(String, String, String?)>[];
    void text(String jobId, String label) {
      final p = _textPayload(jobId);
      // Before the switch: the cost is checked with OpenRouter instead.
      if ((p['quote'] as Map?)?['currency'] != 'CNY') return;
      final receipts = (p['receipts'] as Map?) ?? const {};
      for (final attempt in (p['attempts'] as List).cast<String>()) {
        final r = receipts[attempt] as Map?;
        if (r != null &&
            (r['settled'] == true ||
                r['released'] == true ||
                r['settle'] is Map)) {
          continue;
        }
        out.add((attempt, label, jobId));
      }
    }

    if (failureId.startsWith('text:')) {
      text(key, '整理');
    }
    return out;
  }

  Future<List<UnconfirmedCharge>> _unconfirmedCharges(String failureId) async {
    final out = <UnconfirmedCharge>[];
    var adopted = false;
    for (final candidate in _chargeCandidates(failureId)) {
      final (attempt, label, _) = candidate;
      try {
        final r = await connection.requestSharedBudget(
          '/v1/budget/attempt/$attempt',
        );
        final a = r['attempt'] as Map;
        // Only what the shared ledger still holds as possibly billed.
        if (['sent', 'uncertain'].contains(a['state'])) {
          out.add(UnconfirmedCharge(attempt, label, a['reserve_cny'] as int));
        } else if (a['state'] == 'settled') {
          // Settled already (e.g. a recorded charge whose reply was lost).
          await _adoptSettledCharge(failureId, candidate, a['actual_cny']);
          adopted = true;
        }
      } on ConnectionFailure catch (e) {
        if (e.code != 'attempt_missing') rethrow;
      }
    }
    if (adopted) await _reconcileCharges(failureId);
    return out;
  }

  /// Notes a settlement the shared ledger holds in the local job.
  Future<void> _adoptSettledCharge(
    String failureId,
    (String, String, String?) candidate,
    Object? actual,
  ) async {
    final (attemptId, _, textJob) = candidate;
    if (textJob == null) return;
    final p = _textPayload(textJob);
    p['receipts'] = {
      ...?p['receipts'] as Map?,
      attemptId: {'settled': true, 'confirmed': true, 'cnyMicros': actual},
    };
    await _saveText(
      textJob,
      textJobs.firstWhere((j) => j.id == textJob).status,
      p,
    );
  }

  Future<void> _reconcileCharges(String failureId) async {
    await _reconcileText(failureId.substring(failureId.indexOf(':') + 1));
  }

  Future<void> _recordConfirmedCharge(
    String failureId,
    String attemptId,
    int cnyMicros,
  ) async {
    final candidate = _chargeCandidates(failureId)
        .where((c) => c.$1 == attemptId)
        .firstOrNull;
    if (candidate == null) throw StateError('此请求无需核对，或已核对。');
    final r = await connection.requestSharedBudget(
      '/v1/budget/attempt/$attemptId/settle',
      body: {'confirmedCnyMicros': cnyMicros},
    );
    _readTextBudget((r['budget'] as Map).cast<String, dynamic>());
    await _adoptSettledCharge(
      failureId,
      candidate,
      (r['attempt'] as Map)['actual_cny'],
    );
    await _reconcileCharges(failureId);
  }
}
