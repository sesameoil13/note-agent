part of 'note_workspace.dart';

/// A model result still to be written to its note.
bool _awaitsApply(Map<String, dynamic> payload) =>
    payload['result'] is Map && payload['applyPhase'] != 'applied';

extension _WorkspaceTextProcessing on NoteWorkspace {
  List<WorkspaceTextJob> _textJobs() => List.unmodifiable(
    _database
        .select(
          // Jobs of notes in the 回收站 return with the note on restore.
          "SELECT * FROM text_jobs WHERE vault=? AND note_id NOT IN (SELECT note_id FROM note_disposals WHERE vault=? AND state IN ('deleted','purged'))",
          [vaultStorage.identity, vaultStorage.identity],
        )
        .map(
          (r) => WorkspaceTextJob(
            id: r['id'] as String,
            noteId: r['note_id'] as String,
            status: TextProcessingStatus.read(r['status'] as String),
            message: r['error'] as String? ?? '',
          ),
        ),
  );

  Map<String, dynamic> _textPayload(String id) => jsonDecode(
    _database.select('SELECT payload FROM text_jobs WHERE id=?', [
          id,
        ]).single['payload']
        as String,
  ) as Map<String, dynamic>;
  String? _originalTextFor(String noteId) {
    final documentSource = _document(noteId)?.result?.markdown;
    if (documentSource != null) {
      return documentSource.isEmpty ? '尚未提取正文。' : documentSource;
    }
    final rows = _database.select(
      'SELECT payload FROM text_jobs WHERE note_id=? AND vault=?',
      [noteId, vaultStorage.identity],
    );
    return rows.isEmpty
        ? null
        : (jsonDecode(rows.first['payload'] as String) as Map)['original']
              as String?;
  }

  Future<void> _saveText(
    String id,
    TextProcessingStatus status,
    Map<String, dynamic> payload, {
    String? error,
  }) => _mutate(() async {
    _database.execute(
      'UPDATE text_jobs SET status=?,payload=?,error=? WHERE id=?',
      [status.name, jsonEncode(payload), error, id],
    );
  }, accepted: true);

  Future<void> _applyText(
    String id,
    Map<String, dynamic> payload,
  ) => _mutate(() async {
    final row = _database.select('SELECT note_id FROM text_jobs WHERE id=?', [
      id,
    ]).single;
    final noteId = row['note_id'] as String;
    if (_hasAssociationChange(noteId)) {
      try {
        await _finishAssociationChange(noteId);
      } on FileSystemException {
        _database.execute('UPDATE text_jobs SET status=?,error=? WHERE id=?', [
          TextProcessingStatus.review.name,
          '关联尚未写入，原文与模型结果保留；请重试保存关联。',
          id,
        ]);
        return;
      }
    }
    if (_hasActionChange(noteId)) {
      _database.execute('UPDATE text_jobs SET status=?,error=? WHERE id=?', [
        TextProcessingStatus.review.name,
        '用户修正尚未写入，AI结果未覆盖，请先重试保存修正。',
        id,
      ]);
      return;
    }
    if (notes.firstWhere((n) => n.id == noteId).presentation.userDecided) {
      payload['applyPhase'] = 'applied';
      final pending = notes
          .firstWhere((n) => n.id == noteId)
          .presentation
          .needsConfirmation;
      _database.execute(
        'UPDATE text_jobs SET payload=?,status=?,error=? WHERE id=?',
        [
          jsonEncode(payload),
          (pending
                  ? TextProcessingStatus.review
                  : TextProcessingStatus.completed)
              .name,
          pending ? '行动待确认，未启动提醒。' : null,
          id,
        ],
      );
      return;
    }
    final result = (payload['result'] as Map).cast<String, dynamic>();
    if (result['kind'] == 'review' &&
        ((result['actions'] as List?)?.isEmpty ?? true)) {
      if (!await _tryApplyModelAssociations(id, noteId, payload)) return;
      _database.execute('UPDATE text_jobs SET payload=? WHERE id=?', [
        jsonEncode(payload),
        id,
      ]);
      _database.execute('UPDATE text_jobs SET status=?,error=? WHERE id=?', [
        TextProcessingStatus.review.name,
        '此内容涉及行动或含义不明确，保留原文，待后续待办确认。',
        id,
      ]);
      return;
    }
    var note = notes.firstWhere((n) => n.id == noteId);
    var plan = (payload['writePlan'] as Map?)?.cast<String, dynamic>();
    if (payload['applyPhase'] != 'bodyApplied') {
      if (plan == null) {
        if (note.modifiedAt.toIso8601String() != payload['modifiedAt'] ||
            note.text != (payload['baseText'] ?? payload['original'])) {
          _database.execute(
            'UPDATE text_jobs SET status=?,error=? WHERE id=?',
            [TextProcessingStatus.review.name, '笔记已修改，AI结果保留但未覆盖新内容。', id],
          );
          return;
        }
        final now = _clock();
        final next = WorkspaceNote(
          id: note.id,
          title: note.title,
          text: result['body'] as String,
          createdAt: note.createdAt,
          modifiedAt: now,
          notePath: note.notePath,
          sourcePath: note.sourcePath,
          status: NoteStatus.localSaved,
          document: note.document,
          attachments: note.attachments,
          presentation: _resultPresentation(result, noteId, note.originalText),
        );
        // Associations, attachment entries and extraction limitations may have
        // been edited independently. Compare only the known content prefix,
        // then retain their exact tail rather than regenerating the source.
        const anchor = '\n## 关联\n';
        final before = await vaultStorage.readText(
          vaultStorage.relativePath(note.notePath),
        );
        final position = before.indexOf(anchor);
        if (position < 0 ||
            position != before.lastIndexOf(anchor) ||
            before != (payload['noteSnapshot'] ?? _markdown(note)) ||
            before.substring(0, position) !=
                _markdown(note).split(anchor).first) {
          _database.execute(
            'UPDATE text_jobs SET status=?,error=? WHERE id=?',
            [TextProcessingStatus.review.name, '笔记文件已在其他位置修改，结果未覆盖，请核对原文。', id],
          );
          return;
        }
        var after =
            _markdown(next).split(anchor).first + before.substring(position);
        final oldTime =
            '\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(note.modifiedAt)}\n';
        if (after.endsWith(oldTime)) {
          after =
              '${after.substring(0, after.length - oldTime.length)}\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(now)}\n';
        }
        plan = {
          'before': before,
          'after': after,
          'body': next.text,
          'modifiedAt': now.toIso8601String(),
          'presentation': next.presentation.toJson(),
        };
        payload['writePlan'] = plan;
        _database.execute('UPDATE text_jobs SET payload=? WHERE id=?', [
          jsonEncode(payload),
          id,
        ]);
      }
      try {
        await vaultStorage.replaceText(
          vaultStorage.relativePath(note.notePath),
          plan['before'] as String,
          plan['after'] as String,
          'text-$id',
        );
      } on FileSystemException {
        _database.execute('UPDATE text_jobs SET status=?,error=? WHERE id=?', [
          TextProcessingStatus.review.name,
          '笔记文件已在其他位置修改，结果未覆盖，请核对原文。',
          id,
        ]);
        return;
      }
      _database.execute('BEGIN IMMEDIATE');
      try {
        _database.execute(
          'UPDATE notes SET body=?,modified_at=?,presentation=? WHERE id=?',
          [
            plan['body'],
            plan['modifiedAt'],
            plan['presentation'] == null
                ? null
                : jsonEncode(plan['presentation']),
            noteId,
          ],
        );
        _attachments.noteContentsChanged(noteId, plan['after'] as String);
        // Actions the result no longer has are dropped on paired devices
        // too, rather than kept reminding about.
        if (plan['presentation'] case final Map presentation) {
          final kept = {
            for (final a in presentation['actions'] as List) (a as Map)['id'],
          };
          _tombstoneActions(
            noteId,
            note.actions.map((a) => a.id).where((id) => !kept.contains(id)),
          );
        }
        payload.remove('writePlan');
        payload['applyPhase'] = 'bodyApplied';
        payload['bodyAppliedAt'] = plan['modifiedAt'];
        _database.execute('UPDATE text_jobs SET payload=? WHERE id=?', [
          jsonEncode(payload),
          id,
        ]);
        _database.execute('COMMIT');
      } catch (_) {
        _database.execute('ROLLBACK');
        rethrow;
      }
    }
    note = notes.firstWhere((n) => n.id == noteId);
    if (note.text != result['body'] ||
        (note.modifiedAt.toIso8601String() != payload['bodyAppliedAt'] &&
            note.title != result['title'])) {
      _database.execute('UPDATE text_jobs SET status=?,error=? WHERE id=?', [
        TextProcessingStatus.review.name,
        '正文应用后笔记再次修改，未覆盖较新的标题或正文。',
        id,
      ]);
      return;
    }
    if (_database.select(
      'SELECT note_id FROM note_association_changes WHERE vault=?',
      [vaultStorage.identity],
    ).isNotEmpty) {
      _database.execute('UPDATE text_jobs SET status=?,error=? WHERE id=?', [
        TextProcessingStatus.review.name,
        '请先重试尚未写入的关联，再应用标题与结果。',
        id,
      ]);
      return;
    }
    note = await _renameTextNote(noteId, title: result['title'] as String);
    if (note.status != NoteStatus.localSaved) return;
    if (!await _tryApplyModelAssociations(id, noteId, payload)) return;
    payload['applyPhase'] = 'applied';
    _database.execute(
      'UPDATE text_jobs SET status=?,payload=?,error=NULL WHERE id=?',
      [
        (note.presentation.needsConfirmation
                ? TextProcessingStatus.review
                : TextProcessingStatus.completed)
            .name,
        jsonEncode(payload),
        id,
      ],
    );
  }, accepted: true);
  Future<void> _recoverText() async {
    for (final job in textJobs) {
      final payload = _textPayload(job.id);
      if (_awaitsApply(payload)) {
        await _applyText(job.id, payload);
        continue;
      }
      if (job.status == TextProcessingStatus.sending &&
          payload['automatic'] == true) {
        // Interrupted before a result arrived: it waits to be sent again.
        await _saveText(job.id, TextProcessingStatus.waiting, payload);
      }
    }
  }
}
