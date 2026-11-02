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

/// Why all automatic 整理 is paused: neither is retried automatically.
enum OrganizePause {
  key(
    '百炼拒绝了 Key，自动发送已暂停。请在“连接与设备”中重新连接阿里云百炼 Key，之后会自动继续。',
    '重新连接',
  ),
  balance('阿里云账户余额不足，自动发送已暂停。请在阿里云控制台充值后点“继续发送”。', '继续发送');

  const OrganizePause(this.message, this.action);
  final String message;

  /// The label of the banner's button.
  final String action;
}

/// Why a job an older version left unfinished was not sent (#35).
const _droppedOnUpgrade = '升级后不再发送旧版本未完成的任务';

/// Gaps before the automatic retries of a temporary failure (#39).
const _organizeRetryGaps = [
  Duration(minutes: 1),
  Duration(minutes: 5),
  Duration(minutes: 30),
];

/// Automatic 整理 of every capture (ADR 0004): each is queued once on the
/// device that captured it and sent straight to Bailian. Audio is
/// transcribed first.
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
        }),
      ],
    );
  }

  WorkspaceTextJob? _organizeJob(String noteId) =>
      textJobs.where((j) => j.noteId == noteId).firstOrNull;

  OrganizeStatus? _organizeStatus(String noteId) {
    final job = _organizeJob(noteId);
    if (job == null) return null;
    final payload = _textPayload(job.id);
    // The organizing step of a recording job saved by a version before
    // automatic 整理 (#35); its recording shows its own status.
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

  OrganizePause? _sendingPause() {
    final kind = _database
        .select('SELECT kind FROM organize_pause WHERE vault=?', [
          vaultStorage.identity,
        ])
        .firstOrNull?['kind'];
    return OrganizePause.values.where((p) => p.name == kind).firstOrNull;
  }

  void _setSendingPause(OrganizePause? pause) {
    if (pause == null) {
      _database.execute('DELETE FROM organize_pause WHERE vault=?', [
        vaultStorage.identity,
      ]);
      return;
    }
    _keyConnectionsAtPause = connection.keyConnections;
    _database.execute(
      'INSERT OR REPLACE INTO organize_pause(vault,kind) VALUES (?,?)',
      [vaultStorage.identity, pause.name],
    );
  }

  /// Sends due captures oldest first, one at a time, including captures
  /// queued while the run is under way.
  Future<void> _sendWaiting() async {
    if (_sendingPause() != null) {
      // Connecting a key ends either pause. For a pause saved before this
      // workspace opened, any key connected since the app started counts,
      // even before this vault was opened; at worst one more request is
      // rejected and the pause returns.
      if (connection.keyConnections <= (_keyConnectionsAtPause ?? 0)) return;
      _setSendingPause(null);
    }
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
            "SELECT id,note_id,payload FROM text_jobs WHERE vault=? AND status=? AND note_id NOT IN (SELECT note_id FROM note_disposals WHERE vault=? AND state IN ('deleted','purged')) ORDER BY rowid",
            [
              vaultStorage.identity,
              TextProcessingStatus.waiting.name,
              vaultStorage.identity,
            ],
          )
          .where((row) => !tried.contains(row['id']))
          .firstOrNull;
      if (next == null) return;
      // Oldest first: later captures wait until its retry is due too.
      final retryAt = DateTime.tryParse(
        '${jsonDecode(next['payload'] as String)['retryAt'] ?? ''}',
      );
      if (retryAt != null && _clock().isBefore(retryAt)) return;
      tried.add(next['id'] as String);
      if (!await _sendOrganize(
        next['id'] as String,
        next['note_id'] as String,
      )) {
        return;
      }
    }
  }

  /// False when sending must stop for now (no key connected, or the
  /// network or service is down); other failures don't hold back later
  /// captures.
  Future<bool> _sendOrganize(String id, String noteId) async {
    final payload = _textPayload(id);
    // A capture that got its result is never sent again (#39).
    if (payload['result'] is Map) {
      if (_awaitsApply(payload)) await _applyText(id, payload);
      return true;
    }
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
      payload.remove('reply');
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
      await _saveText(
        id,
        TextProcessingStatus.failed,
        payload,
        error: e.message,
      );
      return true;
    } on TextNetworkFailure catch (e) {
      if (e.code case 'credentials' || 'balance') {
        // Not counted as a try: the capture waits for the account fix.
        payload.remove('request');
        await _saveText(id, TextProcessingStatus.waiting, payload);
        _setSendingPause(
          e.code == 'balance' ? OrganizePause.balance : OrganizePause.key,
        );
        return false;
      }
      final retries = payload['autoRetries'] as int? ?? 0;
      if (e.recoverable && retries < _organizeRetryGaps.length) {
        // Not a result: the capture waits for its next automatic try.
        payload
          ..remove('request')
          ..['autoRetries'] = retries + 1
          ..['retryAt'] = _clock()
              .add(_organizeRetryGaps[retries])
              .toIso8601String();
        await _saveText(
          id,
          TextProcessingStatus.waiting,
          payload,
          error: '${e.message}稍后自动重试（${retries + 1}/3）。',
        );
        return false;
      }
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
  /// are dropped without being sent; their notes and originals stay. Old
  /// re-organizations are removed: a capture is organized only once. What
  /// the old version kept for cost (quotes, holds, receipts) is ignored.
  Future<void> _dropOldEstimateJobs() async {
    // Also jobs of notes in the 回收站, which return with a restore.
    for (final row in _database.select(
      'SELECT id FROM text_jobs WHERE vault=?',
      [vaultStorage.identity],
    )) {
      final id = row['id'] as String;
      final payload = _textPayload(id);
      if (payload['reorganize'] == true) {
        // An applied one already changed its note; a preview never will.
        _database.execute('DELETE FROM text_jobs WHERE id=?', [id]);
        continue;
      }
      final status = _database.select(
        'SELECT status FROM text_jobs WHERE id=?',
        [id],
      ).single['status'];
      // Including the organizing step of an old recording job.
      if (payload['automatic'] == true ||
          payload['result'] is Map ||
          payload['dropped'] == true) {
        // A result whose cost the old version still had to confirm is done.
        if (!TextProcessingStatus.values.any((s) => s.name == status)) {
          _database.execute('UPDATE text_jobs SET status=? WHERE id=?', [
            payload['result'] is Map
                ? TextProcessingStatus.completed.name
                : TextProcessingStatus.cancelled.name,
            id,
          ]);
        }
        continue;
      }
      payload['dropped'] = true;
      await _saveText(
        id,
        TextProcessingStatus.cancelled,
        payload,
        error: '$_droppedOnUpgrade；原文保留。',
      );
    }
  }
}
