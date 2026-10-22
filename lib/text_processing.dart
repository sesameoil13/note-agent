part of 'note_workspace.dart';

extension _WorkspaceTextProcessing on NoteWorkspace {
  List<WorkspaceTextJob> _textJobs() => List.unmodifiable(
    _database
        .select('SELECT * FROM text_jobs WHERE vault=?', [
          vaultStorage.identity,
        ])
        .map((r) {
          final p = (jsonDecode(r['payload'] as String) as Map)
              .cast<String, dynamic>();
          final receipts =
              (p['receipts'] as Map?)?.values.whereType<Map>().toList() ??
              <Map>[];
          final costs = receipts
              .map((receipt) => receipt['usdNanos'])
              .whereType<int>()
              .toList();
          final reply = p['reply'];
          final usage = reply is Map ? reply['usage'] : null;
          int? tokens(String key) =>
              usage is Map && usage[key] is int && (usage[key] as int) >= 0
              ? usage[key] as int
              : null;
          return WorkspaceTextJob(
            id: r['id'] as String,
            noteId: r['note_id'] as String,
            status: TextProcessingStatus.values.byName(r['status'] as String),
            message: r['error'] as String? ?? '',
            canRetry:
                r['status'] == TextProcessingStatus.costPending.name &&
                p['result'] == null,
            estimatedCnyMicros: p['estimatedCnyMicros'] as int? ?? 0,
            quoteDescription: _textQuoteDescription(p['quote']),
            attemptCount: (p['attempts'] as List).length,
            generationIds: List.unmodifiable(
              receipts
                  .map((receipt) => receipt['generationId'])
                  .whereType<String>(),
            ),
            knownCostUsdNanos: costs.isEmpty
                ? null
                : costs.fold<int>(0, (a, b) => a + b),
            inputTokens: tokens('prompt_tokens'),
            outputTokens: tokens('completion_tokens'),
          );
        }),
  );

  String _textQuoteDescription(dynamic value) {
    if (value is! Map) return '尚未取得费率';
    return '固定 DeepSeek V4.1 Flash · 报价 ${value['id']} · 路由 ${value['provider']}\n输入 \$${(value['promptNano'] as int) / 1000}/百万 token；输出 \$${(value['completionNano'] as int) / 1000}/百万 token\n汇率日期 ${value['fxDate']}；冻结换算 ¥${(value['fxMicros'] as int) / 1000000}/USD（含 10% 汇率余量）；每次预留另含 25% 余量。最多 1024 输出 token。';
  }

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
      spentUsdNanos: d['spentUsdNanos'] as int,
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
    if (existing != null) {
      if (existing.status == TextProcessingStatus.cancelled) {
        final payload = _textPayload(existing.id);
        await _reserveNextText(existing.id, noteId, payload);
        return textJobs.firstWhere((j) => j.id == existing.id);
      }
      if ([
        TextProcessingStatus.queued,
        TextProcessingStatus.failed,
      ].contains(existing.status)) {
        await _reserveTextJob(existing.id, noteId, _textPayload(existing.id));
        return textJobs.firstWhere((j) => j.id == existing.id);
      }
      return existing;
    }
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
    await _reserveTextJob(id, noteId, payload);
    return textJobs.firstWhere((j) => j.id == id);
  }

  Future<void> _reserveTextJob(
    String id,
    String noteId,
    Map<String, dynamic> payload, {
    bool refreshed = false,
  }) async {
    try {
      if (payload['quote'] == null) {
        final quoted = await connection.requestSharedBudget(
          '/v1/budget/quote',
          body: {},
        );
        payload['quote'] = quoted['quote'];
      }
      final q = (payload['quote'] as Map).cast<String, dynamic>();
      final attempt = '$id-0';
      payload['associationCandidates'] ??= await _associationCandidates(
        noteId,
        payload['original'] as String,
      );
      payload['request'] = textModelPayload(
        noteId,
        payload['original'] as String,
        q,
        associationCandidates: (payload['associationCandidates'] as List)
            .map((c) => (c as Map).cast<String, dynamic>())
            .toList(),
      );
      payload['attempts'] = [attempt];
      await _saveText(id, TextProcessingStatus.queued, payload);
      Map<String, dynamic> reserved;
      try {
        reserved = await connection.requestSharedBudget(
          '/v1/budget/reserve',
          body: {
            'attemptId': attempt,
            'operationId': id,
            'inputBytes': utf8.encode(jsonEncode(payload['request'])).length,
            'quoteId': q['id'],
          },
        );
      } on ConnectionFailure catch (e) {
        if (e.code != 'quote_expired' || refreshed) rethrow;
        payload.remove('quote');
        return await _reserveTextJob(id, noteId, payload, refreshed: true);
      }
      _readTextBudget((reserved['budget'] as Map).cast<String, dynamic>());
      final state = (reserved['attempt'] as Map)['state'];
      payload['estimatedCnyMicros'] =
          (reserved['attempt'] as Map)['reserve_cny'];
      await _saveText(
        id,
        state == 'reserved'
            ? TextProcessingStatus.prepared
            : TextProcessingStatus.costPending,
        payload,
        error: state == 'reserved' ? null : '已存在发送或结束记录，不会自动重新发送。',
      );
    } on ConnectionFailure catch (e) {
      await _saveText(
        id,
        TextProcessingStatus.failed,
        payload,
        error: e.code == 'budget_exceeded'
            ? '预计费用超过共享剩余额度，已暂停；本机原文保留。'
            : e.message,
      );
      await refreshBudget();
    }
  }

  Future<WorkspaceTextJob> _cancelText(String id) async {
    final job = textJobs.firstWhere((j) => j.id == id);
    if (![
      TextProcessingStatus.prepared,
      TextProcessingStatus.queued,
      TextProcessingStatus.failed,
    ].contains(job.status)) {
      throw StateError('已发送任务可能计费，不能作为未发送取消。');
    }
    final payload = _textPayload(id);
    final attempts = payload['attempts'] as List;
    if (attempts.isNotEmpty) {
      final reply = await connection.requestSharedBudget(
        '/v1/budget/attempt/${attempts.last}/release',
        body: {},
      );
      _readTextBudget((reply['budget'] as Map).cast<String, dynamic>());
      if ((reply['attempt'] as Map)['state'] != 'released') {
        await _saveText(
          id,
          TextProcessingStatus.costPending,
          payload,
          error: '任务已发送，费用预留保留，不能取消实际请求。',
        );
        return textJobs.firstWhere((j) => j.id == id);
      }
    }
    if (attempts.isNotEmpty) {
      payload['receipts'] = {
        ...?payload['receipts'] as Map?,
        attempts.last: {'settled': true, 'released': true},
      };
    }
    await _saveText(
      id,
      TextProcessingStatus.cancelled,
      payload,
      error: '已取消未发送任务，原文保留。',
    );
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
  Future<WorkspaceTextJob> _processText(
    String noteId, {
    int maxRetries = 3,
  }) async {
    final job = await prepareTextProcessing(noteId);
    if (job.status != TextProcessingStatus.prepared) return job;
    final payload = _textPayload(job.id);
    for (var retry = 0; retry <= maxRetries; retry++) {
      final attempt = (payload['attempts'] as List).last as String;
      payload.remove('validationError');
      await _saveText(job.id, TextProcessingStatus.sending, payload);
      try {
        final reply = await connection.sendReservedText(
          attempt,
          (payload['request'] as Map).cast<String, dynamic>(),
        );
        payload['reply'] = reply.data;
        payload['receipts'] = {
          ...?payload['receipts'] as Map?,
          attempt: {
            'generationId': reply.generationId,
            'usdNanos': reply.usdNanos,
            'settled': false,
          },
        };
        try {
          payload['result'] = reply.validated(
            noteId,
            original: payload['original'] as String,
            candidateIds: ((payload['associationCandidates'] as List?) ?? [])
                .map((c) => c['noteId'] as String)
                .toSet(),
          );
        } on ConnectionFailure catch (e) {
          payload['validationError'] = e.message;
        }
        await _saveText(job.id, TextProcessingStatus.costPending, payload);
        final generation = reply.generationId, cost = reply.usdNanos;
        if (generation != null && cost != null) {
          final settled = await connection.requestSharedBudget(
            '/v1/budget/attempt/$attempt/settle',
            body: {'generationId': generation, 'usdNanos': cost},
          );
          _readTextBudget((settled['budget'] as Map).cast<String, dynamic>());
          payload['settled'] =
              (payload['receipts'] as Map).length ==
                  (payload['attempts'] as List).length &&
              (payload['receipts'] as Map).entries.every(
                (entry) =>
                    entry.key == attempt ||
                    (entry.value as Map)['settled'] == true,
              );
          (payload['receipts'] as Map)[attempt]['settled'] = true;
          await _saveText(job.id, TextProcessingStatus.costPending, payload);
        }
        if (payload['validationError'] is String) {
          throw ConnectionFailure(payload['validationError'] as String);
        }
        await _saveText(job.id, TextProcessingStatus.costPending, payload);
        await _applyText(job.id, payload);
        break;
      } on ConnectionFailure catch (e) {
        await _saveText(
          job.id,
          payload['result'] is Map
              ? TextProcessingStatus.costPending
              : TextProcessingStatus.review,
          payload,
          error: e.message,
        );
        await refreshBudget();
        break;
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
        if (!e.recoverable || retry == maxRetries) break;
        // A prior send may already have incurred a charge. Its hold is never
        // recycled into a retry: every attempt needs another atomic admission.
        await Future<void>.delayed(Duration(seconds: 1 << retry));
        try {
          await _reserveNextText(job.id, noteId, payload);
          continue;
        } on ConnectionFailure catch (failure) {
          await _saveText(
            job.id,
            TextProcessingStatus.costPending,
            payload,
            error: failure.code == 'budget_exceeded'
                ? '重试需要另行预留，剩余额度不足，已暂停；原文保留。'
                : failure.message,
          );
          await refreshBudget();
          break;
        }
      } catch (_) {
        await _saveText(
          job.id,
          TextProcessingStatus.costPending,
          payload,
          error: '处理未能确认，原文与费用预留保留，请核对。',
        );
        await refreshBudget();
        break;
      }
    }
    return textJobs.firstWhere((j) => j.id == job.id);
  }

  Future<WorkspaceTextJob> _retryText(String id) async {
    final job = textJobs.firstWhere((j) => j.id == id);
    final payload = _textPayload(id);
    if (job.status != TextProcessingStatus.costPending ||
        payload['result'] != null) {
      throw StateError('仅发送失败且没有可用结果的任务可再次付费重试。');
    }
    try {
      await _reserveNextText(id, job.noteId, payload);
      return await _processText(job.noteId);
    } on ConnectionFailure catch (e) {
      await _saveText(
        id,
        TextProcessingStatus.costPending,
        payload,
        error: e.code == 'budget_exceeded'
            ? '重试需要另行预留，剩余额度不足，已暂停；原文保留。'
            : e.message,
      );
      await refreshBudget();
      return textJobs.firstWhere((j) => j.id == id);
    }
  }

  Future<void> _reserveNextText(
    String id,
    String noteId,
    Map<String, dynamic> payload, {
    bool refreshed = false,
  }) async {
    final pending = payload['pendingReservation'];
    if (pending == null) {
      final quoted = await connection.requestSharedBudget(
        '/v1/budget/quote',
        body: {},
      );
      payload['quote'] = quoted['quote'];
      payload['associationCandidates'] ??= await _associationCandidates(
        noteId,
        payload['original'] as String,
      );
      payload['request'] = textModelPayload(
        noteId,
        payload['original'] as String,
        (payload['quote'] as Map).cast<String, dynamic>(),
        associationCandidates: (payload['associationCandidates'] as List)
            .map((c) => (c as Map).cast<String, dynamic>())
            .toList(),
      );
      payload['pendingReservation'] =
          '$id-${(payload['attempts'] as List).length}';
      await _saveText(id, TextProcessingStatus.costPending, payload);
    }
    final next = payload['pendingReservation'] as String;
    late Map<String, dynamic> admitted;
    try {
      admitted = await connection.requestSharedBudget(
        '/v1/budget/reserve',
        body: {
          'attemptId': next,
          'operationId': id,
          'quoteId': (payload['quote'] as Map)['id'],
          'inputBytes': utf8.encode(jsonEncode(payload['request'])).length,
        },
      );
    } on ConnectionFailure catch (e) {
      if (e.code != 'quote_expired' || refreshed) rethrow;
      // quote_expired is returned only after confirming no existing attempt.
      // Reuse the stable next id, never create a second unknown reservation.
      payload.remove('pendingReservation');
      return await _reserveNextText(id, noteId, payload, refreshed: true);
    }
    _readTextBudget((admitted['budget'] as Map).cast<String, dynamic>());
    if ((admitted['attempt'] as Map)['state'] != 'reserved') {
      throw const ConnectionFailure('此重试已发送，不能自动重发；预留保留。');
    }
    (payload['attempts'] as List).add(next);
    payload.remove('pendingReservation');
    await _saveText(id, TextProcessingStatus.prepared, payload);
  }

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
                  : payload['settled'] == true
                  ? TextProcessingStatus.completed
                  : TextProcessingStatus.costPending)
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
          presentation: _resultPresentation(result, noteId, note.originalText),
        );
        plan = {
          'before': _markdown(note),
          'after': _markdown(next),
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
                : payload['settled'] == true
                ? TextProcessingStatus.completed
                : TextProcessingStatus.costPending)
            .name,
        jsonEncode(payload),
        id,
      ],
    );
  }, accepted: true);
  Future<void> _recoverText() async {
    for (final job in textJobs) {
      final payload = _textPayload(job.id);
      if (payload['result'] is Map && payload['applyPhase'] != 'applied') {
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

  Future<WorkspaceTextJob> _reconcileText(String id) async {
    final payload = _textPayload(id);
    final receipts =
        (payload['receipts'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    try {
      final attempts = <String>{
        ...(payload['attempts'] as List).cast<String>(),
        if (payload['pendingReservation'] is String)
          payload['pendingReservation'] as String,
      };
      for (final attempt in attempts) {
        try {
          final inspected = await connection.requestSharedBudget(
            '/v1/budget/attempt/$attempt',
          );
          final row = (inspected['attempt'] as Map).cast<String, dynamic>();
          _readTextBudget((inspected['budget'] as Map).cast<String, dynamic>());
          if (row['state'] == 'reserved') {
            final released = await connection.requestSharedBudget(
              '/v1/budget/attempt/$attempt/release',
              body: {},
            );
            _readTextBudget(
              (released['budget'] as Map).cast<String, dynamic>(),
            );
            if ((released['attempt'] as Map)['state'] != 'released') {
              throw const ConnectionFailure('发送状态已变化，费用预留保留。');
            }
            receipts[attempt] = {'released': true, 'settled': true};
          } else if (row['state'] == 'released') {
            receipts[attempt] = {'released': true, 'settled': true};
          } else if (row['state'] == 'settled' &&
              row['generation_id'] is String) {
            receipts[attempt] = {
              ...?receipts[attempt] as Map?,
              'generationId': row['generation_id'],
              'usdNanos': row['usd_nanos'],
              'settled': true,
            };
          } else {
            receipts.putIfAbsent(attempt, () => {'settled': false});
          }
        } on ConnectionFailure catch (e) {
          if (e.code != 'attempt_missing') rethrow;
          // A dispatch must first atomically change this persistent admission
          // from reserved to sent. No attempt means no admitted dispatch.
          receipts[attempt] = {'released': true, 'settled': true};
        }
      }
      payload['receipts'] = receipts;
      payload['attempts'] = attempts.toList();
      payload.remove('pendingReservation');
      if (receipts.isEmpty ||
          receipts.values.every(
            (value) => (value as Map)['released'] == true,
          )) {
        await _saveText(
          id,
          TextProcessingStatus.cancelled,
          payload,
          error: '共享账本已确认未发送，预留已释放；原文保留，可重新预估。',
        );
        await refreshBudget();
        return textJobs.firstWhere((j) => j.id == id);
      }
      await _saveText(id, TextProcessingStatus.costPending, payload);
      for (final entry in receipts.entries) {
        final receipt = (entry.value as Map).cast<String, dynamic>();
        if (receipt['released'] == true) continue;
        final generation = receipt['generationId'];
        if (generation is! String) {
          throw const ConnectionFailure(
            '本次发送没有可核对的费用编号；请在 OpenRouter 核对，预留不会自动释放。',
          );
        }
        final cost = await connection.lookupTextCost(generation);
        final settled = await connection.requestSharedBudget(
          '/v1/budget/attempt/${entry.key}/settle',
          body: {'generationId': generation, 'usdNanos': cost},
        );
        _readTextBudget((settled['budget'] as Map).cast<String, dynamic>());
        receipt['usdNanos'] = cost;
        receipt['settled'] = true;
        receipts[entry.key] = receipt;
        payload['receipts'] = receipts;
        payload['settled'] =
            receipts.values.every((v) => (v as Map)['settled'] == true) &&
            receipts.length == (payload['attempts'] as List).length;
        await _saveText(
          id,
          payload['validationError'] is String
              ? TextProcessingStatus.review
              : notes
                    .firstWhere(
                      (n) =>
                          n.id == textJobs.firstWhere((j) => j.id == id).noteId,
                    )
                    .presentation
                    .needsConfirmation
              ? TextProcessingStatus.review
              : payload['settled'] == true && payload['applyPhase'] == 'applied'
              ? TextProcessingStatus.completed
              : TextProcessingStatus.costPending,
          payload,
        );
      }
    } on ConnectionFailure catch (e) {
      await _saveText(
        id,
        TextProcessingStatus.costPending,
        payload,
        error: e.message,
      );
    }
    if (payload['result'] is Map && payload['applyPhase'] != 'applied') {
      await _applyText(id, payload);
    }
    await refreshBudget();
    return textJobs.firstWhere((j) => j.id == id);
  }
}
