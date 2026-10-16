import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'note_files.dart';
import 'note_links.dart';
import 'vault_storage.dart';
import 'recordings.dart';
export 'recordings.dart' hide WorkspaceRecordings;
export 'vault_storage.dart';
export 'note_files.dart' show NoteFilePublisher, AtomicNoteFilePublisher;

/// Local file publication is separate from any future sync acknowledgement.
enum NoteStatus {
  exportPending,
  localSaved,
  exportFailed,
  renamePending,
  renameFailed,
}

/// A collected note, exposed without storage or processing implementation details.
class WorkspaceNote {
  const WorkspaceNote({
    required this.id,
    required this.title,
    required this.text,
    required this.createdAt,
    required this.modifiedAt,
    required this.notePath,
    required this.sourcePath,
    required this.status,
    this.titleCollision = false,
    this.error,
  });

  final String id;
  final String title;
  final String text;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String notePath;
  final String sourcePath;
  final NoteStatus status;

  /// Numbering was needed after the supplied semantic alternatives conflicted.
  final bool titleCollision;
  final String? error;
}

/// The public business boundary shared by the app and behavioral tests.
///
/// Original text and stable identity are committed locally before note export.
/// Use a dedicated test vault during development; no vault is discovered implicitly.
class NoteWorkspace {
  NoteWorkspace._(
    this._database,
    this.vaultStorage,
    this._clock,
    this._createId,
  );

  late final WorkspaceRecordings _recordings;
  final Database _database;
  final VaultStorage vaultStorage;

  /// Compatibility for desktop callers; SAF references are not local paths.
  Directory get vaultDirectory {
    final storage = vaultStorage;
    if (storage is DirectoryVaultStorage) return storage.directory;
    throw UnsupportedError('此笔记库通过系统文档授权访问。');
  }

  final DateTime Function() _clock;
  final String Function() _createId;
  Future<void> _mutations = Future.value();
  int _pendingMutations = 0;
  bool _closing = false;
  Future<void>? _closeFuture;

  static Future<NoteWorkspace> open({
    required Directory localDirectory,
    Directory? vaultDirectory,
    VaultStorage? vaultStorage,
    DateTime Function()? clock,
    String Function()? createId,
    NoteFilePublisher? filePublisher,
    AudioPlatform? audioPlatform,
  }) async {
    if (vaultStorage == null) {
      if (vaultDirectory == null || !await vaultDirectory.exists()) {
        throw const FileSystemException('所选笔记库不存在，请重新选择。');
      }
      vaultStorage = DirectoryVaultStorage(
        Directory(await vaultDirectory.resolveSymbolicLinks()),
        filePublisher: filePublisher,
      );
    }
    await localDirectory.create(recursive: true);
    final database = sqlite3.open(
      p.join(localDirectory.path, 'workspace.sqlite3'),
    );
    database.execute('PRAGMA journal_mode = WAL');
    database.execute('PRAGMA synchronous = FULL');
    database.execute('''CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY,
      vault TEXT NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      note_path TEXT NOT NULL,
      source_path TEXT NOT NULL,
      status TEXT NOT NULL,
      error TEXT
    )''');
    if (!database
        .select('PRAGMA table_info(notes)')
        .any((row) => row['name'] == 'title_collision')) {
      database.execute(
        'ALTER TABLE notes ADD COLUMN title_collision INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!database
        .select('PRAGMA table_info(notes)')
        .any((row) => row['name'] == 'naming_request')) {
      database.execute('ALTER TABLE notes ADD COLUMN naming_request TEXT');
    }
    database.execute('''CREATE TABLE IF NOT EXISTS note_renames (
      note_id TEXT PRIMARY KEY,
      vault TEXT NOT NULL,
      payload TEXT NOT NULL
    )''');
    final workspace = NoteWorkspace._(
      database,
      vaultStorage,
      clock ?? DateTime.now,
      createId ?? _randomId,
    );
    workspace._recordings = WorkspaceRecordings(
      database,
      localDirectory,
      vaultStorage,
      audioPlatform,
      clock ?? DateTime.now,
      createId ?? _randomId,
    );
    await workspace._recordings.recover();
    for (final note in workspace.notes) {
      if (note.status == NoteStatus.exportPending) {
        await workspace.retryNoteExport(note.id);
      }
    }
    for (final row in database.select(
      'SELECT note_id FROM note_renames WHERE vault = ?',
      [vaultStorage.identity],
    )) {
      await workspace._finishRename(row['note_id'] as String);
    }
    return workspace;
  }

  List<WorkspaceNote> get notes => List.unmodifiable(
    _database
        .select(
          'SELECT * FROM notes WHERE vault = ? ORDER BY created_at DESC, id DESC',
          [vaultStorage.identity],
        )
        .map(_noteFromRow),
  );

  /// Find durable originals without requiring an exported note or a network.
  /// An empty query returns recent records in the same order as [notes].
  List<WorkspaceNote> search(String query) {
    final keyword = query.trim().toLowerCase();
    final titleKeyword = _normalizeTitlePunctuation(keyword);
    return List.unmodifiable(
      notes.where(
        (note) =>
            keyword.isEmpty ||
            _normalizeTitlePunctuation(note.title.toLowerCase())
                .contains(titleKeyword) ||
            note.text.toLowerCase().contains(keyword),
      ),
    );
  }

  Future<WorkspaceNote> captureText({
    required String title,
    required String text,
    List<String> semanticTitleCandidates = const [],
  }) => _mutate(() async {
    if (text.trim().isEmpty) throw ArgumentError('请输入要保存的文字。');
    final safeTitle = _safeTitle(title);
    final id = _createId();
    final now = _clock();
    final note = WorkspaceNote(
      id: id,
      title: safeTitle,
      text: text,
      createdAt: now,
      modifiedAt: now,
      notePath: vaultStorage.reference('$safeTitle.md'),
      sourcePath: vaultStorage.reference('attachments/note-agent/$id.txt'),
      status: NoteStatus.exportPending,
    );
    _database.execute(
      '''INSERT INTO notes
      (id, vault, title, body, created_at, modified_at, note_path, source_path, status, naming_request)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        vaultStorage.identity,
        safeTitle,
        text,
        now.toIso8601String(),
        now.toIso8601String(),
        note.notePath,
        note.sourcePath,
        NoteStatus.exportPending.name,
        jsonEncode({
          'title': safeTitle,
          'alternatives': semanticTitleCandidates,
          'allocated': false,
        }),
      ],
    );
    return _retryNoteExport(id);
  });

  /// Candidates are semantic alternatives supplied by the organizing service.
  /// This workspace performs no AI calls and invents no semantic alternatives.
  Future<({String title, bool collision})> _chooseTitle(
    String title,
    List<String> alternatives, {
    String? excludingId,
    bool ownsCurrentFile = true,
  }) async {
    final preferred = _safeTitle(title);
    final current = excludingId == null
        ? null
        : notes.firstWhere((note) => note.id == excludingId);
    final currentPath = current == null || !ownsCurrentFile
        ? null
        : vaultStorage.relativePath(current.notePath);
    final occupied = <String>{
      for (final note in notes)
        if (note.id != excludingId)
          _normalizeTitlePunctuation(note.title).toLowerCase(),
    };
    for (final path in await vaultStorage.listNotePaths()) {
      if (path != currentPath) {
        occupied.add(
          _normalizeTitlePunctuation(
            p.posix.basenameWithoutExtension(path.replaceAll('\\', '/')),
          ).toLowerCase(),
        );
      }
    }
    final candidates = <String>[preferred];
    for (final alternative in alternatives) {
      try {
        candidates.add(_safeTitle(alternative));
      } on ArgumentError {
        // An unusable service alternative must not block a valid capture.
      }
    }
    for (final candidate in candidates) {
      if (!occupied.contains(candidate.toLowerCase()) &&
          ('$candidate.md' == currentPath ||
              !await vaultStorage.exists('$candidate.md'))) {
        return (title: candidate, collision: false);
      }
    }
    var number = 2;
    while (occupied.contains('$preferred ($number)'.toLowerCase()) ||
        await vaultStorage.exists('$preferred ($number).md')) {
      number++;
    }
    return (title: '$preferred ($number)', collision: true);
  }

  String _safeTitle(String title) {
    var safe = _normalizeTitlePunctuation(title)
        .trim()
        .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty || safe == '.' || safe == '..') {
      throw ArgumentError('请输入可用的笔记标题。');
    }
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(safe)) {
      safe = '笔记 $safe';
    }
    return safe;
  }

  /// Obsidian reserves these ASCII characters for headings, blocks, aliases,
  /// comments and wiki syntax. Fullwidth forms retain readable punctuation
  /// (including C＃) while producing one linkable title across all entry points.
  String _normalizeTitlePunctuation(String title) => title.replaceAllMapped(
    RegExp(r'[#|^:%\[\]]'),
    (match) => const {
      '#': '＃',
      '|': '｜',
      '^': '＾',
      ':': '：',
      '%': '％',
      '[': '［',
      ']': '］',
    }[match[0]]!,
  );

  Future<T> _mutate<T>(Future<T> Function() action) {
    if (_closing) {
      return Future<T>.error(StateError('工作区正在关闭，请重新打开后再操作。'));
    }
    _pendingMutations++;
    final result = _mutations.then((_) async {
      try {
        return await action();
      } finally {
        _pendingMutations--;
      }
    });
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Rename without replacing a same-named note. Inbound links are updated
  /// before removing the old file, and a durable plan resumes after restart.
  Future<WorkspaceNote> renameNote(
    String id, {
    required String title,
    List<String> semanticTitleCandidates = const [],
  }) => _mutate(() async {
    if (_renamePlan(id) != null) {
      final recovered = await _finishRename(id);
      if (recovered.status != NoteStatus.localSaved) return recovered;
    }
    final note = notes.firstWhere((note) => note.id == id);
    if (note.status != NoteStatus.localSaved) {
      throw StateError('请先完成笔记库写入，再修改标题。');
    }
    final naming = await _chooseTitle(
      title,
      semanticTitleCandidates,
      excludingId: id,
    );
    if (naming.title == note.title) return note;
    final oldPath = vaultStorage.relativePath(note.notePath);
    final newPath = '${naming.title}.md';
    final original = await vaultStorage.readText(oldPath);
    final now = _clock();
    final sourceTime =
        '\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(note.modifiedAt)}\n';
    var renamed = rewriteNoteLinks(original, oldPath, oldPath, newPath);
    if (renamed.endsWith(sourceTime)) {
      renamed =
          '${renamed.substring(0, renamed.length - sourceTime.length)}\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(now)}\n';
    }
    final updates = <Map<String, String>>[];
    for (final path in await vaultStorage.listNotePaths()) {
      if (path == oldPath) continue;
      final before = await vaultStorage.readText(path);
      final after = rewriteNoteLinks(before, path, oldPath, newPath);
      if (before != after) {
        updates.add({'path': path, 'before': before, 'after': after});
      }
    }
    final plan = {
      'oldPath': oldPath,
      'newPath': newPath,
      'original': original,
      'renamed': renamed,
      'title': naming.title,
      'collision': naming.collision,
      'modifiedAt': now.toIso8601String(),
      'updates': updates,
    };
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'INSERT INTO note_renames (note_id, vault, payload) VALUES (?, ?, ?)',
        [id, vaultStorage.identity, jsonEncode(plan)],
      );
      _database.execute(
        'UPDATE notes SET status = ?, error = NULL WHERE id = ?',
        [NoteStatus.renamePending.name, id],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    return _finishRename(id);
  });

  Map<String, dynamic>? _renamePlan(String id) {
    final rows = _database.select(
      'SELECT payload FROM note_renames WHERE note_id = ? AND vault = ?',
      [id, vaultStorage.identity],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
  }

  Future<WorkspaceNote> _finishRename(String id) async {
    final plan = _renamePlan(id)!;
    try {
      await vaultStorage.publishText(
        plan['newPath'] as String,
        plan['renamed'] as String,
        'rename-$id',
      );
      for (final update in plan['updates'] as List<dynamic>) {
        await vaultStorage.replaceText(
          update['path'] as String,
          update['before'] as String,
          update['after'] as String,
          'rename-$id',
        );
      }
      await vaultStorage.deleteText(
        plan['oldPath'] as String,
        plan['original'] as String,
      );
      _database.execute('BEGIN IMMEDIATE');
      try {
        _database.execute(
          'UPDATE notes SET title = ?, note_path = ?, modified_at = ?, title_collision = ?, status = ?, error = NULL WHERE id = ?',
          [
            plan['title'],
            vaultStorage.reference(plan['newPath'] as String),
            plan['modifiedAt'],
            plan['collision'] == true ? 1 : 0,
            NoteStatus.localSaved.name,
            id,
          ],
        );
        _database.execute('DELETE FROM note_renames WHERE note_id = ?', [id]);
        _database.execute('COMMIT');
      } catch (_) {
        _database.execute('ROLLBACK');
        rethrow;
      }
    } on FileSystemException catch (error) {
      _database.execute('UPDATE notes SET status = ?, error = ? WHERE id = ?', [
        NoteStatus.renameFailed.name,
        error.message,
        id,
      ]);
    }
    return notes.firstWhere((note) => note.id == id);
  }

  /// Retries publication of an existing durable capture without collecting again.
  Future<WorkspaceNote> retryNoteExport(String id) =>
      _mutate(() => _retryNoteExport(id));

  Future<WorkspaceNote> _retryNoteExport(String id) async {
    if (_renamePlan(id) != null) return _finishRename(id);
    var note = notes.firstWhere((note) => note.id == id);
    try {
      final rawRequest =
          _database.select('SELECT naming_request FROM notes WHERE id = ?', [
                id,
              ]).single['naming_request']
              as String?;
      if (rawRequest != null) {
        final request = jsonDecode(rawRequest) as Map<String, dynamic>;
        final path = vaultStorage.relativePath(note.notePath);
        final ownsCurrentFile =
            request['allocated'] == true &&
            await vaultStorage.exists(path) &&
            await vaultStorage.readText(path) == _markdown(note);
        if (!ownsCurrentFile) {
          final naming = await _chooseTitle(
            request['title'] as String,
            (request['alternatives'] as List<dynamic>).cast<String>(),
            excludingId: id,
            ownsCurrentFile: false,
          );
          request['allocated'] = true;
          _database.execute(
            'UPDATE notes SET title = ?, note_path = ?, title_collision = ?, naming_request = ? WHERE id = ?',
            [
              naming.title,
              vaultStorage.reference('${naming.title}.md'),
              naming.collision ? 1 : 0,
              jsonEncode(request),
              id,
            ],
          );
          note = notes.firstWhere((note) => note.id == id);
        }
      }
      await vaultStorage.publishText(
        vaultStorage.relativePath(note.sourcePath),
        note.text,
        note.id,
      );
      await vaultStorage.publishText(
        vaultStorage.relativePath(note.notePath),
        _markdown(note),
        note.id,
      );
      _database.execute(
        'UPDATE notes SET status = ?, error = NULL, naming_request = NULL WHERE id = ?',
        [NoteStatus.localSaved.name, id],
      );
    } on FileSystemException catch (error) {
      _database.execute('UPDATE notes SET status = ?, error = ? WHERE id = ?', [
        NoteStatus.exportFailed.name,
        error.message,
        id,
      ]);
    }
    return notes.firstWhere((note) => note.id == id);
  }

  bool get recordingAvailable => _recordings.audio != null;
  RecordingState get recording => _recordings.state;
  PlaybackState get playback => _recordings.playback;
  List<WorkspaceRecording> get recordings => _recordings.recordings;
  Future<void> startRecording() => _mutate(_recordings.start);
  Future<void> pauseRecording() => _mutate(_recordings.pause);
  Future<void> resumeRecording() => _mutate(_recordings.resume);
  Future<void> refreshRecording() => _recordings.refresh();
  Future<WorkspaceRecording> stopRecording() => _mutate(_recordings.stop);
  Future<WorkspaceRecording> retryRecordingExport(String id) =>
      _mutate(() => _recordings.export(id));
  Future<void> playRecording(String id) => _mutate(() => _recordings.play(id));
  Future<void> refreshPlayback() => _recordings.refreshPlayback();
  Future<void> stopPlayback() => _mutate(_recordings.stopPlayback);

  /// Drain accepted mutations and recording finalization before releasing SQLite.
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    if (_pendingMutations == 0 && !_recordings.needsClosing) {
      _database.close();
      return _closeFuture = Future<void>.value();
    }
    return _closeFuture = _mutations.then((_) async {
      try {
        await _recordings.close();
      } finally {
        _database.close();
      }
    });
  }

  WorkspaceNote _noteFromRow(Row row) => WorkspaceNote(
    id: row['id'] as String,
    title: row['title'] as String,
    text: row['body'] as String,
    createdAt: DateTime.parse(row['created_at'] as String),
    modifiedAt: DateTime.parse(row['modified_at'] as String),
    notePath: row['note_path'] as String,
    sourcePath: row['source_path'] as String,
    status: NoteStatus.values.byName(row['status'] as String),
    titleCollision: row['title_collision'] == 1,
    error: row['error'] as String?,
  );

  String _markdown(WorkspaceNote note) =>
      '''## 正文

${note.text.trimRight()}

## 关联

暂无关联

## 来源

[原始文字](attachments/note-agent/${note.id}.txt)

记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(note.modifiedAt)}
''';

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

String formatNoteTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
