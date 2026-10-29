part of 'note_workspace.dart';

/// Where a capture is in its automatic 整理 (GLOSSARY), as shown on the note.
enum OrganizeStatus {
  waiting('等待发送'),

  /// A recording or imported audio being sent to qwen3-asr-flash.
  transcribing('转写中'),
  organizing('整理中'),
  organized('已整理'),
  failed('失败');

  const OrganizeStatus(this.label);
  final String label;
}

/// Automatic 整理 of every capture (ADR 0004): each is queued once on the
/// device that captured it and sent straight to Bailian, with no estimate,
/// confirmation or budget request. Audio is transcribed first.
extension _WorkspaceOrganizeQueue on NoteWorkspace {
  /// Queues [noteId] for 整理. Only the capturing device calls this, so a
  /// note that arrives from another device is never sent from here.
  /// [original] is the captured text; a document's is its extraction.
  /// [audio] is the source of a recording or imported audio, whose note is
  /// created once its transcript arrives.
  void _queueOrganize(String noteId, {String? original, String? audio}) {
    _database.execute(
      'INSERT INTO text_jobs(id,note_id,vault,status,payload) VALUES (?,?,?,?,?)',
      [
        NoteWorkspace._randomId(),
        noteId,
        vaultStorage.identity,
        TextProcessingStatus.waiting.name,
        jsonEncode({
          'automatic': true,
          'original': ?original,
          'audio': ?audio,
          'attempts': <dynamic>[],
        }),
      ],
    );
  }

  WorkspaceTextJob? _organizeJob(String noteId) => textJobs
      .where((j) => j.noteId == noteId && !j.reorganization)
      .firstOrNull;

  OrganizeStatus? _organizeStatus(String noteId) {
    final job = _organizeJob(noteId);
    if (job == null) return null;
    final payload = _textPayload(job.id);
    if (payload['audioPipeline'] is String) return null;
    // A result was received: the capture is never sent again, even when
    // a later edit kept it from being written (see the job's message).
    if (payload['result'] is Map) return OrganizeStatus.organized;
    return switch (job.status) {
      TextProcessingStatus.waiting => OrganizeStatus.waiting,
      // A recording's original is set once its whole transcript arrived.
      TextProcessingStatus.sending
          when payload['audio'] is String && payload['original'] == null =>
        OrganizeStatus.transcribing,
      TextProcessingStatus.sending => OrganizeStatus.organizing,
      _ when payload['automatic'] == true => OrganizeStatus.failed,
      _ => null,
    };
  }

  /// Sends due captures oldest first, one at a time, including captures
  /// queued while the run is under way.
  Future<void> _sendWaiting() async {
    // Captures made before a key is connected keep waiting.
    if (!connection.state.hasKey) {
      try {
        await connection.restore();
      } on ConnectionFailure {
        return;
      }
      if (!connection.state.hasKey) return;
    }
    // Closing waits for sending, not for the key check above: a secure
    // store that never answers must not keep the workspace open.
    if (_closing) return;
    await _trackText(_sendDue());
  }

  Future<void> _sendDue() async {
    // Each capture is tried at most once per run; one still waiting after
    // its try (e.g. a document being extracted) waits for the next run.
    final tried = <String>{};
    while (!_closing) {
      final next = _database
          .select(
            "SELECT id,note_id FROM text_jobs WHERE vault=? AND status=? AND note_id NOT IN (SELECT note_id FROM note_disposals WHERE vault=? AND state IN ('deleted','purged')) ORDER BY rowid",
            [
              vaultStorage.identity,
              TextProcessingStatus.waiting.name,
              vaultStorage.identity,
            ],
          )
          .where((row) => !tried.contains(row['id']))
          .firstOrNull;
      if (next == null) return;
      tried.add(next['id'] as String);
      if (!await _sendOrganize(
        next['id'] as String,
        next['note_id'] as String,
      )) {
        return;
      }
    }
  }

  /// False when sending must stop for now (no key connected); other
  /// captures are unaffected by this one's failure.
  Future<bool> _sendOrganize(String id, String noteId) async {
    final payload = _textPayload(id);
    final audio = payload['audio'] as String?;
    if (audio != null) {
      final source = _audioQueue.sources
          .where((s) => s.id == audio)
          .firstOrNull;
      // Its original is still being saved or checked.
      if (source == null || !source.originalSaved || source.metadata == null) {
        return true;
      }
    } else if (textProcessingReadiness(noteId) case final readiness
        when !readiness.canPrepare) {
      final note = notes.firstWhere((n) => n.id == noteId);
      // A document with no usable text never becomes ready; anything else
      // (vault write or extraction still pending) waits for the next call.
      if (note.status == NoteStatus.localSaved &&
          note.document?.status == DocumentImportStatus.ready &&
          !_activeDocuments.containsKey(noteId) &&
          !_retryingDocuments.contains(noteId)) {
        await _saveText(
          id,
          TextProcessingStatus.failed,
          payload,
          error: readiness.message,
        );
      }
      return true;
    }
    try {
      // What was captured, never a later edit (GLOSSARY 整理).
      final original =
          payload['original'] as String? ??
          (audio != null
              ? await _transcribe(id, audio, payload)
              : _originalTextFor(noteId)!);
      final note = notes.firstWhere((n) => n.id == noteId);
      payload['original'] = original;
      payload['modifiedAt'] = note.modifiedAt.toIso8601String();
      payload['noteSnapshot'] = await vaultStorage.readText(
        vaultStorage.relativePath(note.notePath),
      );
      if (audio != null) {
        payload['request'] = await _audioTextRequest(noteId, original, payload);
      } else {
        payload['associationCandidates'] = await _associationCandidates(
          noteId,
          original,
        );
        payload['request'] = textModelPayload(
          noteId,
          original,
          const {},
          associationCandidates: (payload['associationCandidates'] as List)
              .map((c) => (c as Map).cast<String, dynamic>())
              .toList(),
        );
      }
      payload
        ..remove('reply')
        ..remove('validationError')
        ..remove('failureKind');
      await _saveText(id, TextProcessingStatus.sending, payload);
      final reply = await connection.sendText(
        (payload['request'] as Map).cast<String, dynamic>(),
      );
      payload['reply'] = reply.data;
      payload['result'] = reply.validated(
        noteId,
        original: original,
        candidateIds: (payload['associationCandidates'] as List)
            .map((c) => c['noteId'] as String)
            .toSet(),
      );
      // Nothing to settle: _applyText then marks the job completed.
      payload['settled'] = true;
      await _saveText(id, TextProcessingStatus.sending, payload);
      await _applyText(id, payload);
      if (audio != null) {
        _database.execute(
          'UPDATE audio_queue SET processing_status=?,processing_reason=NULL WHERE id=? AND vault=?',
          [AudioProcessingStatus.completed.name, audio, vaultStorage.identity],
        );
      }
      return true;
    } on ConnectionFailure catch (e) {
      if (e.code == 'credentials' && payload['reply'] == null) {
        // No key connected yet: the capture keeps waiting.
        payload.remove('request');
        await _saveText(id, TextProcessingStatus.waiting, payload);
        return false;
      }
      payload['validationError'] = e.message;
      payload['failureKind'] = e.code ?? 'invalidResult';
      await _saveText(
        id,
        TextProcessingStatus.failed,
        payload,
        error: e.message,
      );
      return true;
    } on TextNetworkFailure catch (e) {
      payload['failureKind'] =
          e.code ?? (e.recoverable ? 'recoverable' : 'outcomeUnknown');
      await _saveText(
        id,
        TextProcessingStatus.failed,
        payload,
        error: e.message,
      );
      return true;
    } catch (_) {
      // E.g. its note file can't be read. It waits for the next run, or a
      // result is kept for recovery to apply on reopen; later captures go on.
      if (payload['result'] is! Map) {
        payload.remove('request');
        await _saveText(id, TextProcessingStatus.waiting, payload);
      }
      return true;
    }
  }

  /// Old estimate/confirm jobs of every capture that never got a result
  /// are dropped without being sent; their notes and originals stay.
  Future<void> _dropUnfinishedBudgetJobs() async {
    // Also jobs of notes in the 回收站, which return with a restore.
    for (final row in _database.select(
      'SELECT id FROM text_jobs WHERE vault=?',
      [vaultStorage.identity],
    )) {
      final id = row['id'] as String;
      final payload = _textPayload(id);
      // Including the organizing step of an old recording job.
      if (payload['automatic'] == true ||
          payload['reorganize'] == true ||
          payload['result'] is Map ||
          payload['dropped'] == true) {
        continue;
      }
      payload['dropped'] = true;
      await _saveText(
        id,
        TextProcessingStatus.cancelled,
        payload,
        error: '升级后不再发送旧的预估任务；原文保留。',
      );
    }
  }
}
