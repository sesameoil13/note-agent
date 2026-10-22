part of 'note_workspace.dart';

/// A stable note identity with an inspectable model explanation.
class WorkspaceAssociation {
  const WorkspaceAssociation({
    required this.targetNoteId,
    required this.title,
    required this.notePath,
    required this.reason,
  });
  final String targetNoteId, title, notePath, reason;
}

enum TopicSuggestionStatus { pending, confirmed, ignored }

class WorkspaceTopicSuggestion {
  const WorkspaceTopicSuggestion({
    required this.id,
    required this.noteId,
    required this.title,
    required this.reason,
    required this.status,
    this.creationStarted = false,
  });
  final bool creationStarted;
  final String id, noteId, title, reason;
  final TopicSuggestionStatus status;
}

extension _WorkspaceAssociations on NoteWorkspace {
  Future<void> _resolveTopic(String id, bool approve) async {
    final suggestion = _topicSuggestions().firstWhere((s) => s.id == id);
    await _finishAssociationChange(suggestion.noteId);
    final state = _associationState(suggestion.noteId);
    final item =
        (state['suggestions'] as List).firstWhere((s) => s['id'] == id) as Map;
    if (item['status'] != 'pending') return;
    if (!approve && item['targetNoteId'] != null) {
      throw StateError('主题创建已开始，请重试确认完成保存。');
    }
    if (!approve) {
      item['status'] = 'ignored';
      await _writeAssociationState(suggestion.noteId, state);
      return;
    }
    // Save a stable target before publication: retry after interruption must not
    // create a second topic, even if its file was already published.
    item['targetNoteId'] ??= _createId();
    _database.execute(
      'INSERT OR REPLACE INTO note_associations(note_id,vault,payload) VALUES (?,?,?)',
      [suggestion.noteId, vaultStorage.identity, jsonEncode(state)],
    );
    final targetId = item['targetNoteId'] as String;
    final existing = notes.where((n) => n.id == targetId).firstOrNull;
    final target = existing == null
        ? await _captureText(
            title: item['title'] as String,
            text: item['reason'] as String,
            noteId: targetId,
          )
        : existing.status == NoteStatus.localSaved
        ? existing
        : await _retryNoteExport(targetId);
    if (target.status != NoteStatus.localSaved) {
      throw StateError('主题尚未写入笔记库，请重试确认。');
    }
    final links = state['links'] as List;
    if (!links.any((l) => l['noteId'] == targetId)) {
      links.add({
        'noteId': targetId,
        'reason': item['reason'],
        'removed': false,
      });
    }
    item['status'] = 'confirmed';
    await _writeAssociationState(suggestion.noteId, state);
  }

  Map<String, dynamic> _associationState(String noteId) {
    final rows = _database.select(
      'SELECT payload FROM note_associations WHERE note_id=? AND vault=?',
      [noteId, vaultStorage.identity],
    );
    return rows.isEmpty
        ? {'links': <dynamic>[], 'suggestions': <dynamic>[]}
        : jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
  }

  List<WorkspaceAssociation> _associations(String noteId) => List.unmodifiable([
    for (final link in _associationState(noteId)['links'] as List)
      if (link['removed'] != true &&
          _associationTarget(link['noteId'] as String) != null)
        WorkspaceAssociation(
          targetNoteId: link['noteId'] as String,
          title:
              _associationTarget(link['noteId'] as String)!['title'] as String,
          notePath:
              _associationTarget(link['noteId'] as String)!['path'] as String,
          reason: link['reason'] as String,
        ),
  ]);

  Map<String, String>? _associationTarget(String id) {
    final rows = _database.select(
      'SELECT title,note_path FROM notes WHERE id=? AND vault=?',
      [id, vaultStorage.identity],
    );
    if (rows.isNotEmpty) {
      return {
        'title': rows.single['title'] as String,
        'path': rows.single['note_path'] as String,
      };
    }
    return null;
  }

  List<WorkspaceTopicSuggestion> _topicSuggestions() => List.unmodifiable([
    for (final row in _database.select(
      'SELECT note_id,payload FROM note_associations WHERE vault=?',
      [vaultStorage.identity],
    ))
      for (final s
          in (jsonDecode(row['payload'] as String) as Map)['suggestions']
              as List)
        WorkspaceTopicSuggestion(
          id: s['id'] as String,
          noteId: row['note_id'] as String,
          title: s['title'] as String,
          reason: s['reason'] as String,
          status: TopicSuggestionStatus.values.byName(s['status'] as String),
          creationStarted: s['targetNoteId'] != null,
        ),
  ]);

  String _associationLink(Map link) {
    final target = _associationTarget(link['noteId'] as String);
    if (target == null) return '';
    final path = vaultStorage.relativePath(target['path']!);
    // Destinations come only from the vault, never model-generated Markdown.
    return '- [[${p.withoutExtension(path)}]]';
  }

  String _associationMarkdown(String noteId) {
    final links = (_associationState(noteId)['links'] as List)
        .where((l) => l['removed'] != true)
        .map((l) => _associationLink(l as Map))
        .where((s) => s.isNotEmpty);
    return links.isEmpty ? '暂无关联' : links.join('\n');
  }

  Future<List<Map<String, dynamic>>> _associationCandidates(
    String noteId,
    String text,
  ) async {
    final query = _associationTerms(text);
    final candidates = _database.select(
      'SELECT id,title,body FROM notes WHERE vault=? AND id<>? AND status=? ORDER BY created_at DESC,id DESC',
      [vaultStorage.identity, noteId, NoteStatus.localSaved.name],
    );
    final ranked = candidates.map((row) {
      final title = row['title'] as String, body = row['body'] as String;
      final terms = _associationTerms('$title $body');
      final titleTerms = _associationTerms(title);
      final score =
          query.where(terms.contains).length +
          query.where(titleTerms.contains).length * 3;
      return (score: score, id: row['id'] as String, title: title, body: body);
    }).toList()..sort((a, b) => b.score.compareTo(a.score));
    return [
      for (final c in ranked.take(12))
        {
          'noteId': c.id,
          'title': c.title,
          'excerpt': c.body.substring(0, min(c.body.length, 400)),
        },
    ];
  }

  Future<bool> _tryApplyModelAssociations(
    String id,
    String noteId,
    Map<String, dynamic> payload,
  ) async {
    if (_database.select('SELECT note_id FROM note_renames WHERE vault=?', [
      vaultStorage.identity,
    ]).isNotEmpty) {
      _database.execute('UPDATE text_jobs SET status=?,error=? WHERE id=?', [
        TextProcessingStatus.review.name,
        '请先完成标题修改，再重试应用关联。',
        id,
      ]);
      return false;
    }
    try {
      await _applyModelAssociations(id, noteId, payload);
      return true;
    } on FileSystemException {
      _database.execute('UPDATE text_jobs SET status=?,error=? WHERE id=?', [
        TextProcessingStatus.review.name,
        '关联尚未写入，原文与模型结果保留；请核对笔记后重试保存关联。',
        id,
      ]);
      return false;
    }
  }

  Future<void> _applyModelAssociations(
    String id,
    String noteId,
    Map<String, dynamic> payload,
  ) async {
    final result = payload['result'] as Map;
    if (result['manifestVersion'] != 3 ||
        payload['associationsApplied'] == true) {
      return;
    }
    await _finishAssociationChange(noteId);
    final state = _associationState(noteId);
    final links = state['links'] as List;
    for (final link in result['associations'] as List) {
      if (!links.any((l) => l['noteId'] == link['noteId']) &&
          _associationTarget(link['noteId'] as String) != null) {
        links.add({...link as Map, 'removed': false});
      }
    }
    final suggestions = state['suggestions'] as List;
    for (var i = 0; i < (result['newTopics'] as List).length; i++) {
      final topic = result['newTopics'][i] as Map;
      final sid = '$id-topic-$i';
      if (!suggestions.any((s) => s['id'] == sid)) {
        suggestions.add({...topic, 'id': sid, 'status': 'pending'});
      }
    }
    await _writeAssociationState(noteId, state);
    payload['associationsApplied'] = true;
  }

  Future<void> _writeAssociationState(
    String noteId,
    Map<String, dynamic> state,
  ) async {
    if (_hasAssociationChange(noteId)) throw StateError('关联修改尚未写入，请先重试保存。');
    if (_hasActionChange(noteId)) throw StateError('请先保存行动修正。');
    if (_database.select('SELECT note_id FROM note_renames WHERE vault=?', [
      vaultStorage.identity,
    ]).isNotEmpty) {
      throw StateError('标题修改尚未写入，请先完成标题修改。');
    }
    final note = notes.firstWhere((n) => n.id == noteId);
    if (note.status != NoteStatus.localSaved || _renamePlan(noteId) != null) {
      throw StateError('请先完成笔记写入。');
    }
    const start = '\n## 关联\n\n', end = '\n\n## 来源\n';
    final before = await vaultStorage.readText(
      vaultStorage.relativePath(note.notePath),
    );
    final position = before.indexOf(start), ending = before.indexOf(end);
    if (position < 0 ||
        ending <= position ||
        position != before.lastIndexOf(start) ||
        ending != before.lastIndexOf(end) ||
        before.substring(0, position) != _markdown(note).split(start).first) {
      throw const FileSystemException('笔记内容已在其他位置修改，未覆盖关联；请先核对。');
    }
    final previousLines = (_associationState(noteId)['links'] as List)
        .where((l) => l['removed'] != true)
        .map((l) => _associationLink(l as Map))
        .toSet();
    final manual = before
        .substring(position + start.length, ending)
        .split('\n')
        .where(
          (line) =>
              line.trim().isNotEmpty &&
              line != '暂无关联' &&
              !previousLines.contains(line),
        )
        .toList();
    final lines = <String>{
      ...manual,
      for (final l in state['links'] as List)
        if (l['removed'] != true && _associationLink(l as Map).isNotEmpty)
          _associationLink(l),
    };
    final modifiedAt = _clock();
    var after =
        '${before.substring(0, position)}$start${lines.isEmpty ? '暂无关联' : lines.join('\n')}${before.substring(ending)}';
    final oldTime =
        '\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(note.modifiedAt)}\n';
    if (after.endsWith(oldTime)) {
      after =
          '${after.substring(0, after.length - oldTime.length)}\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(modifiedAt)}\n';
    }
    _database.execute(
      'INSERT INTO note_association_changes(note_id,vault,payload) VALUES (?,?,?)',
      [
        noteId,
        vaultStorage.identity,
        jsonEncode({
          'path': vaultStorage.relativePath(note.notePath),
          'before': before,
          'after': after,
          'state': state,
          'operation': _createId(),
          'modifiedAt': modifiedAt.toIso8601String(),
        }),
      ],
    );
    await _finishAssociationChange(noteId);
  }

  bool _hasAssociationChange(String noteId) => _database.select(
    'SELECT note_id FROM note_association_changes WHERE note_id=? AND vault=?',
    [noteId, vaultStorage.identity],
  ).isNotEmpty;

  Future<void> _finishAssociationChange(String noteId) async {
    final rows = _database.select(
      'SELECT payload FROM note_association_changes WHERE note_id=? AND vault=?',
      [noteId, vaultStorage.identity],
    );
    if (rows.isEmpty) return;
    final plan = jsonDecode(rows.single['payload'] as String) as Map;
    await vaultStorage.replaceText(
      plan['path'] as String,
      plan['before'] as String,
      plan['after'] as String,
      'association-${plan['operation']}',
    );
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'INSERT OR REPLACE INTO note_associations(note_id,vault,payload) VALUES (?,?,?)',
        [noteId, vaultStorage.identity, jsonEncode(plan['state'])],
      );
      _database.execute(
        'UPDATE notes SET modified_at=? WHERE id=? AND vault=?',
        [plan['modifiedAt'], noteId, vaultStorage.identity],
      );
      _attachments.noteContentsChanged(noteId, plan['after'] as String);
      _database.execute(
        'DELETE FROM note_association_changes WHERE note_id=? AND vault=?',
        [noteId, vaultStorage.identity],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> _recoverAssociationChanges() async {
    for (final row in _database.select(
      'SELECT note_id FROM note_association_changes WHERE vault=?',
      [vaultStorage.identity],
    )) {
      try {
        await _finishAssociationChange(row['note_id'] as String);
      } on FileSystemException {
        /* Durable plan remains retryable. */
      }
    }
  }
}

// Generic local retrieval narrows context; the model decides semantic relations,
// including paraphrases. No topic dictionary or mutually exclusive categories.
Set<String> _associationTerms(String value) {
  final terms = <String>{};
  for (final match in RegExp(
    r'[\p{L}\p{N}]+',
    unicode: true,
  ).allMatches(value.toLowerCase())) {
    final word = match[0]!;
    if (word.length <= 24) terms.add(word);
    for (var i = 0; i < word.length - 1; i++) {
      terms.add(word.substring(i, i + 2));
    }
  }
  return terms;
}
