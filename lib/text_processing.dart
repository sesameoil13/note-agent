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
        note.attachments.isNotEmpty)
      throw StateError('请先保存文字笔记。');
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
      final attempt = '${id}-0';
      payload['quote'] = q;
      payload['attempts'] = [attempt];
      final reserved = await connection.requestSharedBudget(
        '/v1/budget/reserve',
        body: {
          'attemptId': attempt,
          'operationId': id,
          'inputBytes': utf8.encode(note.text).length,
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
}
