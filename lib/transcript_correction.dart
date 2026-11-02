part of 'note_workspace.dart';

/// A transcript corrected in the App is a local edit only: it is written to
/// the vault and synced like any edit, and never sent to AI (GLOSSARY 整理).
extension _WorkspaceTranscriptCorrection on NoteWorkspace {
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
}
