part of 'note_workspace.dart';

/// A validated model re-organization that has not been applied. It is
/// [stale] when the note changed after the preview's base content: per
/// ADR 0002 the newer content wins and the preview can only be discarded.
class WorkspaceReorganizationPreview {
  const WorkspaceReorganizationPreview({
    required this.jobId,
    required this.noteId,
    required this.title,
    required this.body,
    required this.kind,
    required this.actions,
    required this.basedOn,
    required this.stale,
  });
  final String jobId, noteId, title, body;
  final NoteKind kind;
  final List<WorkspaceAction> actions;
  final DateTime basedOn;
  final bool stale;
}

extension _WorkspaceReorganization on NoteWorkspace {
  /// The App-corrected complete transcript, once written to the vault.
  String? _correctedSource(String noteId) {
    final rows = _database.select(
      'SELECT payload FROM source_corrections WHERE note_id=? AND vault=?',
      [noteId, vaultStorage.identity],
    );
    if (rows.isEmpty) return null;
    final p = jsonDecode(rows.single['payload'] as String) as Map;
    return p['phase'] == 'applied' ? p['text'] as String : null;
  }

  Future<WorkspaceNote> _correctTranscript(String noteId, String text) async {
    final note = notes.firstWhere((n) => n.id == noteId);
    if (_audioQueue.sources.every((s) => s.outputNoteId != noteId)) {
      throw StateError('只有录音笔记的完整转写可在此更正。');
    }
    if (text.trim().isEmpty || utf8.encode(text).length > 4000000) {
      throw ArgumentError('更正后的转写不能为空或超过上限。');
    }
    if (note.status != NoteStatus.localSaved) {
      throw StateError('请先完成笔记库写入，再更正转写。');
    }
    if (textJobs.any(
      (j) =>
          j.noteId == noteId &&
          [
            TextProcessingStatus.prepared,
            TextProcessingStatus.sending,
          ].contains(j.status),
    )) {
      throw StateError('整理任务已预留或正在发送；请先完成或取消，再更正转写。');
    }
    final path = vaultStorage.relativePath(note.sourcePath);
    final before = await vaultStorage.readText(path);
    if (before != note.originalText) {
      throw StateError('完整转写已在其他位置修改；未覆盖较新的内容，请先核对。');
    }
    final rows = _database.select(
      'SELECT payload FROM source_corrections WHERE note_id=? AND vault=?',
      [noteId, vaultStorage.identity],
    );
    final previous = rows.isEmpty
        ? null
        : (jsonDecode(rows.single['payload'] as String) as Map)
              .cast<String, dynamic>();
    final payload = <String, dynamic>{
      // The first machine transcript is kept locally for audit and comparison.
      'machine': previous?['machine'] ?? before,
      'text': text,
      'before': before,
      'phase': 'planned',
      'correctedAt': _clock().toIso8601String(),
    };
    _database.execute(
      'INSERT INTO source_corrections(note_id,vault,payload) VALUES (?,?,?) '
      'ON CONFLICT(note_id) DO UPDATE SET payload=excluded.payload',
      [noteId, vaultStorage.identity, jsonEncode(payload)],
    );
    await _finishCorrection(noteId);
    return notes.firstWhere((n) => n.id == noteId);
  }

  Future<void> _finishCorrection(String noteId) async {
    final rows = _database.select(
      'SELECT payload FROM source_corrections WHERE note_id=? AND vault=?',
      [noteId, vaultStorage.identity],
    );
    if (rows.isEmpty) return;
    final p = (jsonDecode(rows.single['payload'] as String) as Map)
        .cast<String, dynamic>();
    if (p['phase'] == 'applied') return;
    final note = notes.firstWhere((n) => n.id == noteId);
    try {
      await vaultStorage.replaceText(
        vaultStorage.relativePath(note.sourcePath),
        p['before'] as String,
        p['text'] as String,
        'correct-$noteId',
      );
    } on FileSystemException {
      // Changed elsewhere meanwhile: the later content wins, nothing is lost.
      _database.execute(
        'DELETE FROM source_corrections WHERE note_id=? AND vault=?',
        [noteId, vaultStorage.identity],
      );
      throw StateError('完整转写已在其他位置修改；未覆盖较新的内容，请先核对。');
    }
    p['phase'] = 'applied';
    _database.execute(
      'UPDATE source_corrections SET payload=? WHERE note_id=? AND vault=?',
      [jsonEncode(p), noteId, vaultStorage.identity],
    );
  }

  Future<void> _recoverCorrections() async {
    for (final row in _database.select(
      'SELECT note_id FROM source_corrections WHERE vault=?',
      [vaultStorage.identity],
    )) {
      try {
        await _finishCorrection(row['note_id'] as String);
      } on StateError {
        /* The externally changed transcript is kept. */
      }
    }
  }

  Future<WorkspaceTextJob> _prepareReorganization(String noteId) async {
    final note = notes.firstWhere((n) => n.id == noteId);
    if (note.status != NoteStatus.localSaved || _renamePlan(noteId) != null) {
      throw StateError('请先完成笔记库写入，再重新整理。');
    }
    if (_hasActionChange(noteId) || _hasAssociationChange(noteId)) {
      throw StateError('上次修正尚未写入，请先重试保存。');
    }
    final doc = note.document;
    if (doc != null && doc.result?.markdown.trim().isEmpty != false) {
      throw StateError('没有可整理的提取文字，原件保留。');
    }
    final unfinished = textJobs.where(
      (j) =>
          j.noteId == noteId &&
          ([
                TextProcessingStatus.queued,
                TextProcessingStatus.prepared,
                TextProcessingStatus.sending,
              ].contains(j.status) ||
              (j.reorganization && _reorganizationPreview(j.id) != null)),
    );
    if (unfinished.isNotEmpty) {
      throw StateError('此笔记已有待发送任务或未处理的预览；请先确认、取消或放弃。');
    }
    final id = _createId();
    final payload = <String, dynamic>{
      'original': note.originalText,
      'baseText': note.text,
      'modifiedAt': note.modifiedAt.toIso8601String(),
      'noteSnapshot': await vaultStorage.readText(
        vaultStorage.relativePath(note.notePath),
      ),
      'attempts': <dynamic>[],
      'reorganize': true,
    };
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
    return textJobs.firstWhere((j) => j.id == id);
  }

  WorkspaceReorganizationPreview? _reorganizationPreview(String jobId) {
    final p = _textPayload(jobId);
    if (p['reorganize'] != true ||
        p['applyPhase'] != 'preview' ||
        p['result'] is! Map) {
      return null;
    }
    final job = textJobs.firstWhere((j) => j.id == jobId);
    final note = notes.firstWhere((n) => n.id == job.noteId);
    final result = (p['result'] as Map).cast<String, dynamic>();
    final presentation = _resultPresentation(
      result,
      note.id,
      note.originalText,
      actionPrefix: 'r$jobId',
    );
    return WorkspaceReorganizationPreview(
      jobId: jobId,
      noteId: note.id,
      title: result['title'] as String,
      body: result['body'] as String,
      kind: presentation.kind,
      actions: presentation.actions,
      basedOn: DateTime.parse(p['modifiedAt'] as String),
      stale:
          note.modifiedAt.toIso8601String() != p['modifiedAt'] ||
          note.text != p['baseText'] ||
          note.originalText != p['original'],
    );
  }

  List<WorkspaceReorganizationPreview> _reorganizationPreviews() => [
    for (final job in textJobs.where((j) => j.reorganization))
      ?_reorganizationPreview(job.id),
  ];

  Future<WorkspaceReorganizationPreview> _runReorganizationPreview(
    String jobId,
  ) async {
    final job = textJobs.firstWhere((j) => j.id == jobId);
    if (!job.reorganization) throw StateError('这不是重新整理任务。');
    await _sendText(jobId, job.noteId);
    final preview = _reorganizationPreview(jobId);
    if (preview == null) {
      throw StateError(
        textJobs.firstWhere((j) => j.id == jobId).message.isEmpty
            ? '未取得可用的整理结果，原文保留。'
            : textJobs.firstWhere((j) => j.id == jobId).message,
      );
    }
    return preview;
  }

  Future<WorkspaceNote> _applyReorganization(String jobId) async {
    final preview = _reorganizationPreview(jobId);
    if (preview == null) throw StateError('没有可应用的整理预览。');
    final note = notes.firstWhere((n) => n.id == preview.noteId);
    final payload = _textPayload(jobId);
    final current = await vaultStorage.readText(
      vaultStorage.relativePath(note.notePath),
    );
    if (preview.stale || current != payload['noteSnapshot']) {
      throw StateError('预览生成后笔记已修改；较新的内容保留，此预览不会覆盖，请放弃后重新整理。');
    }
    payload['applyPhase'] = 'approved';
    _database.execute('UPDATE text_jobs SET payload=? WHERE id=?', [
      jsonEncode(payload),
      jobId,
    ]);
    await _applyText(jobId, payload);
    final after = _textPayload(jobId);
    if (after['applyPhase'] != 'applied') {
      throw StateError(textJobs.firstWhere((j) => j.id == jobId).message);
    }
    return notes.firstWhere((n) => n.id == preview.noteId);
  }

  Future<void> _discardReorganization(String jobId) async {
    final job = textJobs.firstWhere((j) => j.id == jobId);
    final p = _textPayload(jobId);
    if (!job.reorganization || p['applyPhase'] != 'preview') {
      throw StateError('没有可放弃的整理预览。');
    }
    // Discarding never releases or forgets the paid attempt; it stays
    // reconcilable in the budget panel.
    p['applyPhase'] = 'discarded';
    await _saveText(
      jobId,
      p['settled'] == true
          ? TextProcessingStatus.completed
          : TextProcessingStatus.costPending,
      p,
      error: '整理预览已放弃，笔记未改变。',
    );
  }
}
