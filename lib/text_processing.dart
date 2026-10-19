part of 'note_workspace.dart';

extension _WorkspaceTextProcessing on NoteWorkspace {
  List<WorkspaceTextJob> _textJobs() => List.unmodifiable(
    _database
        .select('SELECT * FROM text_jobs WHERE vault=?', [
          vaultStorage.identity,
        ])
        .map(
          (r) => WorkspaceTextJob(
            id: r['id'] as String,
            noteId: r['note_id'] as String,
            status: TextProcessingStatus.values.byName(r['status'] as String),
            message: r['error'] as String? ?? '',
            attemptCount:
                ((jsonDecode(r['payload'] as String) as Map)['attempts']
                        as List)
                    .length,
          ),
        ),
  );
  Future<void> _refreshTextBudget() async {
    try {
      _readTextBudget(await connection.requestSharedBudget('/v1/budget'));
    } on ConnectionFailure catch (e) {
      _budget = WorkspaceBudgetState(message: '${e.message} 本机保存仍可使用。');
    }
  }

  void _readTextBudget(Map<String, dynamic> d) {
    _budget = WorkspaceBudgetState(
      monthLabel: d['month'] as String,
      limitCnyMicros: d['limitCnyMicros'] as int,
      spentCnyMicros: d['spentCnyMicros'] as int,
      reservedCnyMicros: d['reservedCnyMicros'] as int,
      unknownCnyMicros: d['unknownCnyMicros'] as int,
      connected: true,
      paused:
          d['disputed'] == true ||
          (d['spentCnyMicros'] as int) + (d['reservedCnyMicros'] as int) >=
              (d['limitCnyMicros'] as int),
      message: d['disputed'] == true
          ? '费用存在不一致，暂停新收费任务；本机保存仍可使用。'
          : '三端共享账本；预付余额需在 OpenRouter 官网查看，本 App 不接收管理 Key。',
    );
  }

  Future<void> _setTextBudget(int micros) async {
    _readTextBudget(
      await connection.requestSharedBudget(
        '/v1/budget/settings',
        body: {'limitCnyMicros': micros},
      ),
    );
  }

  Future<WorkspaceTextJob> _prepareText(String noteId) async {
    final existing = textJobs.where((j) => j.noteId == noteId).firstOrNull;
    if (existing != null) return existing;
    final note = notes.firstWhere((n) => n.id == noteId);
    if (note.status != NoteStatus.localSaved ||
        note.document != null ||
        note.attachments.isNotEmpty) {
      throw StateError('请先保存文字笔记。');
    }
    final id = _createId();
    final payload = <String, dynamic>{
      'original': note.text,
      'modifiedAt': note.modifiedAt.toIso8601String(),
      'attempts': <dynamic>[],
    };
    await _mutate(() async {
      _database.execute(
        'INSERT INTO text_jobs(id,note_id,vault,status,payload) VALUES (?,?,?,?,?)',
        [
          id,
          noteId,
          vaultStorage.identity,
          TextProcessingStatus.queued.name,
          jsonEncode(payload),
        ],
      );
    });
    try {
      final quoted = await connection.requestSharedBudget(
        '/v1/budget/quote',
        body: {},
      );
      final q = (quoted['quote'] as Map).cast<String, dynamic>();
      final attempt = '$id-0';
      payload['quote'] = q;
      payload['request'] = textModelPayload(noteId, note.text, q);
      payload['attempts'] = [attempt];
      final reserved = await connection.requestSharedBudget(
        '/v1/budget/reserve',
        body: {
          'attemptId': attempt,
          'operationId': id,
          'inputBytes': utf8.encode(jsonEncode(payload['request'])).length,
          'quoteId': q['id'],
        },
      );
      _readTextBudget((reserved['budget'] as Map).cast<String, dynamic>());
      await _mutate(() async {
        _database.execute(
          'UPDATE text_jobs SET status=?,payload=?,error=NULL WHERE id=?',
          [TextProcessingStatus.prepared.name, jsonEncode(payload), id],
        );
      });
    } on ConnectionFailure catch (e) {
      await _mutate(() async {
        _database.execute('UPDATE text_jobs SET status=?,error=? WHERE id=?', [
          TextProcessingStatus.failed.name,
          e.code == 'budget_exceeded' ? '预计费用超过共享剩余额度，已暂停；本机原文保留。' : e.message,
          id,
        ]);
      });
      await refreshBudget();
    }
    return textJobs.firstWhere((j) => j.id == id);
  }

  Map<String, dynamic> _textPayload(String id) => jsonDecode(
    _database.select('SELECT payload FROM text_jobs WHERE id=?', [
          id,
        ]).single['payload']
        as String,
  ) as Map<String, dynamic>;
  String? _originalTextFor(String noteId) {
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
  Future<WorkspaceTextJob> _processText(String noteId) async {
    final job = await prepareTextProcessing(noteId);
    if (job.status != TextProcessingStatus.prepared) return job;
    final payload = _textPayload(job.id);
    final attempt = (payload['attempts'] as List).last as String;
    await _saveText(job.id, TextProcessingStatus.sending, payload);
    try {
      final reply = await connection.sendReservedText(
        attempt,
        (payload['request'] as Map).cast<String, dynamic>(),
      );
      payload['reply'] = reply.data;
      await _saveText(job.id, TextProcessingStatus.costPending, payload);
      final generation = reply.generationId, cost = reply.usdNanos;
      if (generation != null && cost != null) {
        final settled = await connection.requestSharedBudget(
          '/v1/budget/attempt/$attempt/settle',
          body: {'generationId': generation, 'usdNanos': cost},
        );
        _readTextBudget((settled['budget'] as Map).cast<String, dynamic>());
        payload['settled'] = true;
        await _saveText(job.id, TextProcessingStatus.costPending, payload);
      }
      payload['result'] = reply.validated(noteId);
      await _saveText(job.id, TextProcessingStatus.costPending, payload);
      await _applyText(job.id, payload);
    } on ConnectionFailure catch (e) {
      await _saveText(
        job.id,
        TextProcessingStatus.review,
        payload,
        error: e.message,
      );
      await refreshBudget();
    } on TextNetworkFailure catch (e) {
      await connection
          .requestSharedBudget(
            '/v1/budget/attempt/$attempt/uncertain',
            body: {},
          )
          .catchError((_) => <String, dynamic>{});
      await _saveText(
        job.id,
        TextProcessingStatus.costPending,
        payload,
        error: e.message,
      );
      await refreshBudget();
    } catch (_) {
      await _saveText(
        job.id,
        TextProcessingStatus.costPending,
        payload,
        error: '处理未能确认，原文与费用预留保留，请核对。',
      );
      await refreshBudget();
    }
    return textJobs.firstWhere((j) => j.id == job.id);
  }

  Future<void> _applyText(String id, Map<String, dynamic> payload) => _mutate(
    () async {
      final row = _database.select('SELECT note_id FROM text_jobs WHERE id=?', [
        id,
      ]).single;
      final noteId = row['note_id'] as String;
      final result = (payload['result'] as Map).cast<String, dynamic>();
      if (result['kind'] != 'ordinary') {
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
              note.text != payload['original']) {
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
          );
          plan = {
            'before': _markdown(note),
            'after': _markdown(next),
            'body': next.text,
            'modifiedAt': now.toIso8601String(),
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
          _database.execute(
            'UPDATE text_jobs SET status=?,error=? WHERE id=?',
            [TextProcessingStatus.review.name, '笔记文件已在其他位置修改，结果未覆盖，请核对原文。', id],
          );
          return;
        }
        _database.execute('BEGIN IMMEDIATE');
        try {
          _database.execute(
            'UPDATE notes SET body=?,modified_at=? WHERE id=?',
            [plan['body'], plan['modifiedAt'], noteId],
          );
          _attachments.noteContentsChanged(noteId, plan['after'] as String);
          payload.remove('writePlan');
          payload['applyPhase'] = 'bodyApplied';
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
      note = await _renameTextNote(noteId, title: result['title'] as String);
      if (note.status != NoteStatus.localSaved) return;
      payload['applyPhase'] = 'applied';
      _database.execute(
        'UPDATE text_jobs SET status=?,payload=?,error=NULL WHERE id=?',
        [
          (payload['settled'] == true
                  ? TextProcessingStatus.completed
                  : TextProcessingStatus.costPending)
              .name,
          jsonEncode(payload),
          id,
        ],
      );
    },
    accepted: true,
  );
  Future<void> _recoverText() async {
    for (final job in textJobs) {
      final payload = _textPayload(job.id);
      if (payload['result'] is Map &&
          (payload['writePlan'] != null ||
              payload['applyPhase'] == 'bodyApplied')) {
        await _applyText(job.id, payload);
        continue;
      }
      if (job.status == TextProcessingStatus.sending) {
        await _saveText(
          job.id,
          TextProcessingStatus.costPending,
          payload,
          error: '上次请求中断，可能已计费，预留保留；请先核对费用，不自动重发。',
        );
      }
    }
  }
}
