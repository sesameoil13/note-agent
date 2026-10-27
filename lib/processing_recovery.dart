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
      failures.add(
        WorkspaceProcessingFailure(
          id: 'text:${job.id}',
          source: ProcessingFailureSource.text,
          noteId: job.noteId,
          title: titleOf(job.noteId, '文字笔记'),
          message: job.message,
          recovery: recovery,
          automaticRetriesUsed: p['autoRetries'] as int? ?? 0,
          needsAccountAction: _accountFailureKinds.contains(kind),
          estimatedCnyMicros: job.estimatedCnyMicros,
        ),
      );
    }
    final jobs = {for (final job in audioJobs) job.sourceId: job};
    for (final source in _audioQueue.sources) {
      final job = jobs[source.id];
      if (job != null) {
        final p = _audioPayload(source.id);
        // Organized already: only a fee is left to check, never a re-run.
        final organized =
            p['textJob'] is String &&
            _textPayload(p['textJob'] as String)['result'] != null;
        final recovery = switch (job.status) {
          AudioJobStatus.paused when job.transcript == null =>
            ProcessingRecovery.retry,
          AudioJobStatus.paused when p['audioSettled'] != true || organized =>
            ProcessingRecovery.reconcileCost,
          AudioJobStatus.paused => ProcessingRecovery.reorganizeOnly,
          AudioJobStatus.prepared
              when p['previous'] != null || p['organizationOnly'] == true =>
            ProcessingRecovery.confirmPrepared,
          _ => null,
        };
        if (recovery == null) continue;
        failures.add(
          WorkspaceProcessingFailure(
            id: 'audio:${source.id}',
            source: ProcessingFailureSource.audio,
            noteId: job.noteId,
            title: titleOf(job.noteId, source.originalName),
            message: job.message,
            recovery: recovery,
            needsAccountAction: _accountFailureKinds.contains(p['failureKind']),
            estimatedCnyMicros: job.estimatedCnyMicros,
          ),
        );
        continue;
      }
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
        final job = textJobs.firstWhere((j) => j.id == key);
        if (job.status == TextProcessingStatus.failed) {
          await prepareTextProcessing(job.noteId);
        } else if (job.status == TextProcessingStatus.prepared) {
          await processTextNote(job.noteId);
        } else {
          await retryTextProcessing(key);
        }
      case ProcessingFailureSource.audio:
        if (audioJobs.every((j) => j.sourceId != key)) {
          if (failure.recovery == ProcessingRecovery.reselectOriginal) {
            throw StateError('原件尚未完整保存，请重新选择同一录音文件导入。');
          }
          await retryAudioProcessing(key);
          return;
        }
        switch (failure.recovery) {
          case ProcessingRecovery.retry:
            await prepareAudioRetry(key);
          case ProcessingRecovery.reconcileCost:
            await reconcileAudioProcessing(key);
          case ProcessingRecovery.reorganizeOnly:
            await prepareAudioOrganization(key);
          case ProcessingRecovery.confirmPrepared:
            await confirmAudioProcessing(key);
          default:
            throw StateError('此失败项正在等待自动重试。');
        }
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
    } else if (failureId.startsWith('audio:') &&
        audioJobs.any((j) => j.sourceId == key)) {
      final current = _audioPayload(key);
      Map<String, dynamic>? p = current;
      while (p != null) {
        final parts = _parts(p);
        for (final part in parts) {
          if (part['state'] == 'reserved' ||
              part['settled'] == true ||
              part['receipt'] != null) {
            continue;
          }
          out.add((
            part['attempt'] as String,
            parts.length > 1
                ? '转写第 ${(part['index'] as int) + 1}/${parts.length} 段'
                : '转写',
            null,
          ));
        }
        p = (p['previous'] as Map?)?.cast<String, dynamic>();
      }
      if (current['textJob'] is String) {
        text(current['textJob'] as String, '整理');
      }
    }
    return out;
  }

  Future<List<UnconfirmedCharge>> _unconfirmedCharges(String failureId) async {
    final out = <UnconfirmedCharge>[];
    for (final (attempt, label, _) in _chargeCandidates(failureId)) {
      try {
        final r = await connection.requestSharedBudget(
          '/v1/budget/attempt/$attempt',
        );
        final a = r['attempt'] as Map;
        // Only what the shared ledger still holds as possibly billed.
        if (['sent', 'uncertain'].contains(a['state'])) {
          out.add(UnconfirmedCharge(attempt, label, a['reserve_cny'] as int));
        }
      } on ConnectionFailure catch (e) {
        if (e.code != 'attempt_missing') rethrow;
      }
    }
    return out;
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
    final actual = (r['attempt'] as Map)['actual_cny'];
    final key = failureId.substring(failureId.indexOf(':') + 1);
    final textJob = candidate.$3;
    if (textJob != null) {
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
    } else {
      final p = _audioPayload(key);
      Map<String, dynamic>? payload = p;
      while (payload != null) {
        for (final part in (payload['parts'] as List?) ?? const []) {
          if ((part as Map)['attempt'] == attemptId) {
            part
              ..['settled'] = true
              ..['confirmed'] = true
              ..['cnyMicros'] = actual;
          }
        }
        payload = (payload['previous'] as Map?)?.cast<String, dynamic>();
      }
      await _saveAudioJob(key, _audioJob(key).status, p);
    }
    if (failureId.startsWith('audio:')) {
      await _reconcileAudio(key);
    } else {
      await _reconcileText(key);
    }
  }
}
