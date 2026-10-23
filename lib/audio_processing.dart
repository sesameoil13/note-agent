part of 'note_workspace.dart';

enum AudioJobStatus {
  preparing,
  prepared,
  sending,
  transcribed,
  organizing,
  completed,
  paused,
  cancelled,
}

class WorkspaceAudioJob {
  const WorkspaceAudioJob({
    required this.sourceId,
    required this.status,
    required this.estimatedCnyMicros,
    required this.description,
    required this.message,
    this.transcript,
    this.canCancel = false,
    this.noteId,
    this.knownCostUsdNanos,
    this.generationId,
  });
  final String sourceId, description, message;
  final AudioJobStatus status;
  final bool canCancel;
  final int estimatedCnyMicros;
  final String? transcript, noteId, generationId;
  final int? knownCostUsdNanos;
}

extension _WorkspaceAudioProcessing on NoteWorkspace {
  List<WorkspaceAudioJob> _audioJobs() => List.unmodifiable(
    _database
        .select('SELECT * FROM audio_jobs WHERE vault=?', [
          vaultStorage.identity,
        ])
        .map((r) {
          final p = jsonDecode(r['payload'] as String) as Map;
          final aq = p['audioQuote'] as Map?;
          return WorkspaceAudioJob(
            sourceId: r['source_id'] as String,
            status: AudioJobStatus.values.byName(r['status'] as String),
            estimatedCnyMicros: p['estimate'] as int? ?? 0,
            description: p['organizationOnly'] == true
                ? '本次仅整理已有完整转写，不重新上传音频；需确认新的整理费用。附带最多 12 条本库相关标题及每条最多 400 字片段用于关联；完整请求最多 20000 编码字节、1024 输出 token，不自动重发。\n${_textQuoteDescription(p['textQuote'])}'
                : aq == null
                ? '尚未取得转写和整理费率。'
                : '一次确认包含完整音频转写（$transcriptionModelId）及固定 DeepSeek V4.1 Flash 整理。\n转写按全部已知路由最高秒价预留：\$${(aq['secondNano'] as int) / 1000000000}/秒，最少 ${aq['minimumSeconds']} 秒，时长另含 25% 余量；两阶段均含 25% 费用余量。汇率日期 ${aq['fxDate']}。\n转写不保证远端价格封顶；超出预留将如实记账并暂停后续收费。\n整理会附带最多 12 条本库相关标题及每条最多 400 字片段用于关联；完整请求最多 20000 编码字节、1024 输出 token；超限保留完整转写并暂停，不截断或隐式分段。两阶段均不自动重发。报价到期需重新预估。\n${_textQuoteDescription(p['textQuote'])}',
            canCancel: p['consented'] != true || p['organizationOnly'] == true,
            message: r['error'] as String? ?? '',
            transcript: p['transcript'] as String?,
            noteId: p['noteId'] as String?,
            knownCostUsdNanos: p['usdNanos'] as int?,
            generationId: p['generationId'] as String?,
          );
        }),
  );
  WorkspaceAudioJob _audioJob(String id) =>
      audioJobs.firstWhere((j) => j.sourceId == id);
  Map<String, dynamic> _audioPayload(String id) => (jsonDecode(
    _database.select(
          'SELECT payload FROM audio_jobs WHERE source_id=? AND vault=?',
          [id, vaultStorage.identity],
        ).single['payload']
        as String,
  ) as Map).cast<String, dynamic>();
  Future<void> _saveAudioJob(
    String id,
    AudioJobStatus status,
    Map<String, dynamic> payload, {
    String? error,
  }) => _mutate(() async {
    _database.execute(
      'INSERT INTO audio_jobs(source_id,vault,status,payload,error) VALUES (?,?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET status=excluded.status,payload=excluded.payload,error=excluded.error',
      [id, vaultStorage.identity, status.name, jsonEncode(payload), error],
    );
    if ([AudioJobStatus.completed, AudioJobStatus.paused].contains(status)) {
      _database.execute(
        'UPDATE audio_queue SET processing_status=?,processing_reason=? WHERE id=? AND vault=?',
        [
          status == AudioJobStatus.completed
              ? AudioProcessingStatus.completed.name
              : AudioProcessingStatus.failed.name,
          error,
          id,
          vaultStorage.identity,
        ],
      );
    }
  }, accepted: true);

  Future<List<int>> _verifiedAudio(
    WorkspaceAudioSource source, {
    Map? expected,
  }) async {
    if (!source.originalSaved ||
        source.metadata == null ||
        source.byteLength > 25000000) {
      throw const ConnectionFailure('原件尚未通过检查或超过 25 MB，原音保留。');
    }
    final metadata = await _audioQueue.inspector
        .inspectAudioSource(source.originalPath)
        .timeout(const Duration(seconds: 10));
    final format = metadata.container.toLowerCase();
    if (!['wav', 'mp3', 'm4a', 'aac'].contains(format) ||
        metadata.duration.inMilliseconds < 1 ||
        metadata.duration.inMilliseconds > 600000 ||
        metadata.duration != source.metadata!.duration ||
        metadata.container != source.metadata!.container) {
      throw const ConnectionFailure('音频格式或时长未能核对（最多十分钟），原音保留。');
    }
    final file = File(source.originalPath);
    if (await file.length() != source.byteLength) {
      throw const ConnectionFailure('音频原件已改变，不能沿用预估。');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      bytes.addAll(chunk);
      if (bytes.length > 25000000) {
        throw const ConnectionFailure('音频原件超过上传上限，未上传。');
      }
    }
    if (bytes.length != source.byteLength) {
      throw const ConnectionFailure('音频原件已改变，未上传。');
    }
    final magic = switch (format) {
      'wav' =>
        bytes.length >= 12 &&
            ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
            ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WAVE',
      'm4a' =>
        bytes.length >= 12 &&
            ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp',
      'aac' => bytes.length >= 2 && bytes[0] == 255 && (bytes[1] & 246) == 240,
      'mp3' =>
        bytes.length >= 3 &&
            ((bytes[0] == 73 && bytes[1] == 68 && bytes[2] == 51) ||
                (bytes[0] == 255 && (bytes[1] & 224) == 224)),
      _ => false,
    };
    final digest = (await const DartSha256().hash(bytes)).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (!magic ||
        digest != source.digest ||
        (expected != null &&
            (expected['digest'] != digest ||
                expected['format'] != format ||
                expected['durationMs'] != metadata.duration.inMilliseconds))) {
      throw const ConnectionFailure('音频内容与已检查原件不符，未上传。');
    }
    return bytes;
  }

  Future<WorkspaceAudioJob> _prepareAudio(
    String id, {
    bool retry = false,
  }) async {
    final existing = audioJobs.where((j) => j.sourceId == id).firstOrNull;
    if (existing != null &&
        existing.status != AudioJobStatus.cancelled &&
        !retry) {
      return existing;
    }
    Map<String, dynamic>? previous;
    if (retry) {
      if (existing?.status != AudioJobStatus.paused ||
          existing?.transcript != null) {
        throw StateError('只有尚无完整转写的暂停任务可另行预估上传。已有转写应仅重试整理。');
      }
      previous = _audioPayload(id);
      await _releaseUnsentAudio(previous);
    }
    final source = _audioQueue.source(id);
    await _verifiedAudio(source);
    final operation = _createId();
    final p = <String, dynamic>{
      'previous': ?previous,
      'operation': operation,
      'audioAttempt': '$operation-audio',
      'textAttempt': '$operation-text',
      'noteId': source.outputNoteId,
      'source': {
        'sourceId': id,
        'digest': source.digest,
        'format': source.metadata!.container.toLowerCase(),
        'durationMs': source.metadata!.duration.inMilliseconds,
      },
      'inputBytes': source.byteLength,
    };
    await _saveAudioJob(id, AudioJobStatus.preparing, p);
    try {
      p['audioQuote'] = (await connection.requestSharedBudget(
        '/v1/budget/quote',
        body: {'purpose': 'transcription'},
      ))['quote'];
      p['textQuote'] = (await connection.requestSharedBudget(
        '/v1/budget/quote',
        body: {},
      ))['quote'];
      await _saveAudioJob(id, AudioJobStatus.preparing, p);
      final a = await connection.requestSharedBudget(
        '/v1/budget/reserve',
        body: {
          'attemptId': p['audioAttempt'],
          'operationId': operation,
          'quoteId': (p['audioQuote'] as Map)['id'],
          'purpose': 'transcription',
          'inputBytes': source.byteLength,
          'source': p['source'],
        },
      );
      _readTextBudget((a['budget'] as Map).cast<String, dynamic>());
      final t = await connection.requestSharedBudget(
        '/v1/budget/reserve',
        body: {
          'attemptId': p['textAttempt'],
          'operationId': operation,
          'quoteId': (p['textQuote'] as Map)['id'],
          'inputBytes': 20000,
        },
      );
      _readTextBudget((t['budget'] as Map).cast<String, dynamic>());
      if ((a['attempt'] as Map)['state'] != 'reserved' ||
          (t['attempt'] as Map)['state'] != 'reserved') {
        throw const ConnectionFailure('此任务已有发送记录，不能重复发送。');
      }
      p['estimate'] =
          ((a['attempt'] as Map)['reserve_cny'] as int) +
          ((t['attempt'] as Map)['reserve_cny'] as int);
      await _saveAudioJob(id, AudioJobStatus.prepared, p);
    } catch (e) {
      await _releaseUnsentAudio(p);
      await _saveAudioJob(
        id,
        AudioJobStatus.paused,
        p,
        error: e is ConnectionFailure ? e.message : '预估中断，原音保留；请核对共享预留。',
      );
    }
    return _audioJob(id);
  }

  Future<void> _releaseUnsentAudio(Map<String, dynamic> p) async {
    for (final key in ['audioAttempt', 'textAttempt']) {
      try {
        final r = await connection.requestSharedBudget(
          '/v1/budget/attempt/${p[key]}/release',
          body: {},
        );
        _readTextBudget((r['budget'] as Map).cast<String, dynamic>());
      } catch (_) {
        /* Unknown dispatches retain their central holds. */
      }
    }
  }

  Future<WorkspaceAudioJob> _cancelAudio(String id) async {
    final job = _audioJob(id);
    if (![
      AudioJobStatus.preparing,
      AudioJobStatus.prepared,
      AudioJobStatus.paused,
    ].contains(job.status)) {
      throw StateError('正在发送的任务不能作为未发送取消。');
    }
    final p = _audioPayload(id);
    if (p['consented'] == true && p['organizationOnly'] != true) {
      throw StateError('已确认任务请先核对费用，不会自动重传。');
    }
    await _releaseUnsentAudio(p);
    // A lost send response is never considered unsent based on local state.
    for (final key
        in p['organizationOnly'] == true
            ? ['textAttempt']
            : ['audioAttempt', 'textAttempt']) {
      try {
        final r = await connection.requestSharedBudget(
          '/v1/budget/attempt/${p[key]}',
        );
        if ((r['attempt'] as Map)['state'] != 'released') {
          throw const ConnectionFailure('已有发送记录，预留保留。');
        }
      } on ConnectionFailure catch (e) {
        if (e.code != 'attempt_missing') rethrow;
      }
    }
    await _saveAudioJob(
      id,
      p['organizationOnly'] == true
          ? AudioJobStatus.paused
          : AudioJobStatus.cancelled,
      p,
      error: '未发送任务已取消，原音保留。',
    );
    return _audioJob(id);
  }

  Future<WorkspaceAudioJob> _confirmAudio(String id) async {
    final job = _audioJob(id);
    final p = _audioPayload(id);
    if (job.status != AudioJobStatus.prepared) return job;
    try {
      if (p['organizationOnly'] != true) {
        final bytes = await _verifiedAudio(
          _audioQueue.source(id),
          expected: p['source'] as Map,
        );
        for (final q in [p['audioQuote'], p['textQuote']]) {
          if ((q as Map)['expiresAt'] as int <=
              _clock().millisecondsSinceEpoch) {
            throw const ConnectionFailure('两阶段报价已到期，请取消后重新预估。');
          }
        }
        p['consented'] = true;
        await _saveAudioJob(id, AudioJobStatus.sending, p);
        final reply = await connection.sendReservedAudio(
          p['audioAttempt'] as String,
          bytes: bytes,
          format: (p['source'] as Map)['format'] as String,
        );
        p['transcript'] = reply.text;
        p['generationId'] = reply.generationId;
        p['usdNanos'] = reply.usdNanos;
        await _saveAudioJob(id, AudioJobStatus.transcribed, p);
        // Save a locally readable complete transcript even when settlement fails.
        await _materializeTranscript(id, p);
        await _settleAudio(p);
        if (p['audioSettled'] != true || budget.paused) {
          throw const ConnectionFailure('转写费用尚未核清或超出预留；完整转写保留，未发送整理。');
        }
        await _createAudioTextJob(id, p);
      } else {
        if ((p['textQuote'] as Map)['expiresAt'] as int <=
            _clock().millisecondsSinceEpoch) {
          throw const ConnectionFailure('整理报价已到期，请取消后重新预估。');
        }
      }
      final note = notes.firstWhere((n) => n.id == p['noteId']);
      await _saveAudioJob(id, AudioJobStatus.organizing, p);
      final done = await _processText(note.id, maxRetries: 0);
      await _saveAudioJob(
        id,
        done.status == TextProcessingStatus.completed ||
                done.status == TextProcessingStatus.review
            ? AudioJobStatus.completed
            : AudioJobStatus.paused,
        p,
        error: done.message,
      );
    } catch (e) {
      if (e is TextNetworkFailure && e.generationId != null) {
        p['generationId'] = e.generationId;
      }
      await _releaseUnsentAudio(p);
      await _saveAudioJob(
        id,
        AudioJobStatus.paused,
        p,
        error: e is TextNetworkFailure
            ? e.message
            : e is ConnectionFailure
            ? e.message
            : '处理结果未能确认，原音、已完成转写和费用预留保留，不自动重传。',
      );
    }
    await refreshBudget();
    return _audioJob(id);
  }

  Future<Map<String, dynamic>> _audioTextRequest(Map<String, dynamic> p) async {
    p['associationCandidates'] ??= await _associationCandidates(
      p['noteId'] as String,
      p['transcript'] as String,
    );
    final candidates = (p['associationCandidates'] as List)
        .map((c) => (c as Map).cast<String, dynamic>())
        .toList();
    Map<String, dynamic> request() => textModelPayload(
      p['noteId'] as String,
      p['transcript'] as String,
      (p['textQuote'] as Map).cast<String, dynamic>(),
      associationCandidates: candidates,
    );
    var encoded = request();
    // Optional context yields to the complete transcript. Freeze exactly the
    // sent identities so omitted candidates cannot be invented by the model.
    while (utf8.encode(jsonEncode(encoded)).length > 20000 &&
        candidates.isNotEmpty) {
      candidates.removeLast();
      encoded = request();
    }
    p['associationCandidates'] = candidates;
    return encoded;
  }

  Future<void> _createAudioTextJob(String id, Map<String, dynamic> p) async {
    final note = notes.firstWhere((n) => n.id == p['noteId']);
    final request = await _audioTextRequest(p);
    if (utf8.encode(jsonEncode(request)).length > 20000) {
      throw const ConnectionFailure('完整转写超过本次整理上限，原音与完整转写保留；不会截断或额外上传。');
    }
    if ((p['textQuote'] as Map)['expiresAt'] as int <=
        _clock().millisecondsSinceEpoch) {
      throw const ConnectionFailure('整理报价已到期，完整转写保留；请重新预估整理。');
    }
    final textId = '${p['operation']}-organize';
    final textPayload = <String, dynamic>{
      'original': p['transcript'],
      'modifiedAt': note.modifiedAt.toIso8601String(),
      'noteSnapshot': await vaultStorage.readText(
        vaultStorage.relativePath(note.notePath),
      ),
      'quote': p['textQuote'],
      'request': request,
      'attempts': [p['textAttempt']],
      'audioPipeline': id,
      'associationCandidates': p['associationCandidates'],
    };
    p['textJob'] = textId;
    await _mutate(() async {
      _database.execute('BEGIN IMMEDIATE');
      try {
        _database.execute(
          'INSERT INTO text_jobs(id,note_id,vault,status,payload) VALUES (?,?,?,?,?)',
          [
            textId,
            note.id,
            vaultStorage.identity,
            TextProcessingStatus.prepared.name,
            jsonEncode(textPayload),
          ],
        );
        _database.execute(
          'UPDATE audio_jobs SET payload=? WHERE source_id=? AND vault=?',
          [jsonEncode(p), id, vaultStorage.identity],
        );
        _database.execute('COMMIT');
      } catch (_) {
        _database.execute('ROLLBACK');
        p.remove('textJob');
        rethrow;
      }
    }, accepted: true);
  }

  Future<WorkspaceAudioJob> _prepareAudioOrganization(String id) async {
    final p = _audioPayload(id);
    if (_audioJob(id).status != AudioJobStatus.paused ||
        p['transcript'] is! String ||
        p['audioSettled'] != true) {
      throw StateError('请先核对转写费用；仅已保存转写且费用已核清的暂停任务可重新预估整理。');
    }
    try {
      p['organizationOnly'] = true;
      await _releaseUnsentAudio(p);
      if (p['textJob'] is String) {
        final textId = p['textJob'] as String;
        final t = _textPayload(textId);
        if (t['result'] != null) throw StateError('已有整理结果，请核对已有内容，不重复计费。');
        await _reserveNextText(textId, p['noteId'] as String, t);
        p['textQuote'] = t['quote'];
        p['textAttempt'] = (t['attempts'] as List).last;
      } else {
        final operation = _createId();
        p['operation'] = operation;
        p['textAttempt'] = '$operation-text';
        p['textQuote'] = (await connection.requestSharedBudget(
          '/v1/budget/quote',
          body: {},
        ))['quote'];
        await _saveAudioJob(id, AudioJobStatus.preparing, p);
        // Validate the entire request before reserving or asking for consent.
        final request = await _audioTextRequest(p);
        if (utf8.encode(jsonEncode(request)).length > 20000) {
          throw const ConnectionFailure('完整转写超过整理上限，未发送或截断。');
        }
        final r = await connection.requestSharedBudget(
          '/v1/budget/reserve',
          body: {
            'attemptId': p['textAttempt'],
            'operationId': operation,
            'quoteId': (p['textQuote'] as Map)['id'],
            'inputBytes': 20000,
          },
        );
        _readTextBudget((r['budget'] as Map).cast<String, dynamic>());
        await _createAudioTextJob(id, p);
      }
      final r = await connection.requestSharedBudget(
        '/v1/budget/attempt/${p['textAttempt']}',
      );
      p['estimate'] = (r['attempt'] as Map)['reserve_cny'];
      p['organizationOnly'] = true;
      await _saveAudioJob(
        id,
        AudioJobStatus.prepared,
        p,
        error: '仅重新整理已有完整转写，不再次上传音频。此整理需单独确认费用。',
      );
      return _audioJob(id);
    } catch (e) {
      await _releaseUnsentAudio(p);
      await _saveAudioJob(
        id,
        AudioJobStatus.paused,
        p,
        error: e is ConnectionFailure
            ? e.message
            : e is StateError
            ? e.message.toString()
            : '整理预估未能确认，完整转写和费用预留保留，请稍后核对。',
      );
      return _audioJob(id);
    }
  }

  Future<void> _settleAudio(Map<String, dynamic> p) async {
    if (p['generationId'] == null || p['usdNanos'] == null) return;
    final r = await connection.requestSharedBudget(
      '/v1/budget/attempt/${p['audioAttempt']}/settle',
      body: {'generationId': p['generationId'], 'usdNanos': p['usdNanos']},
    );
    _readTextBudget((r['budget'] as Map).cast<String, dynamic>());
    p['audioSettled'] = true;
  }

  Future<void> _materializeTranscript(String id, Map<String, dynamic> p) =>
      _mutate(() async {
        final source = _audioQueue.source(id);
        _database.execute(
          'UPDATE audio_queue SET transcript=? WHERE id=? AND vault=?',
          [p['transcript'], id, vaultStorage.identity],
        );
        await _materializeAudioNote(
          source,
          AudioOrganizedNote(title: '录音转写', text: p['transcript'] as String),
        );
      }, accepted: true);
  Future<void> _recoverAudioJobs() async {
    for (final job in audioJobs) {
      if ([
        AudioJobStatus.sending,
        AudioJobStatus.organizing,
        AudioJobStatus.preparing,
        AudioJobStatus.transcribed,
      ].contains(job.status)) {
        final p = _audioPayload(job.sourceId);
        if (p['transcript'] is String) {
          try {
            await _materializeTranscript(job.sourceId, p);
          } catch (_) {
            /* Recovery retains the transcript even if export is unavailable. */
          }
        }
        await _saveAudioJob(
          job.sourceId,
          AudioJobStatus.paused,
          p,
          error: '上次处理已中断，原音与已有转写保留；不会自动重传，请核对费用。',
        );
      }
    }
  }

  Future<WorkspaceAudioJob> _reconcileAudio(String id) async {
    final p = _audioPayload(id);
    try {
      Map<String, dynamic>? receipt = p;
      var unknown = false;
      while (receipt != null) {
        if (receipt['generationId'] is String) {
          receipt['usdNanos'] = await connection.lookupTextCost(
            receipt['generationId'] as String,
          );
          await _settleAudio(receipt);
        } else if (receipt['consented'] == true &&
            receipt['audioSettled'] != true) {
          unknown = true;
        }
        receipt = (receipt['previous'] as Map?)?.cast<String, dynamic>();
      }
      p['previousUnknown'] = unknown;
      final textId = p['textJob'];
      if (textId is String) await _reconcileText(textId);
      await _releaseUnsentAudio(p);
      await _saveAudioJob(
        id,
        _audioJob(id).status,
        p,
        error: p['audioSettled'] == true && p['previousUnknown'] != true
            ? '费用已核对；不重新调用模型。'
            : '缺少可核对的转写费用编号，未知预留保留，请在 OpenRouter 核对。',
      );
    } catch (e) {
      await _saveAudioJob(
        id,
        AudioJobStatus.paused,
        p,
        error: e is ConnectionFailure ? e.message : '费用尚未核对，预留保留。',
      );
    }
    await refreshBudget();
    return _audioJob(id);
  }
}
