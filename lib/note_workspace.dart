import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'note_files.dart';
export 'note_files.dart' show NoteFilePublisher, AtomicNoteFilePublisher;

/// Local file publication is separate from any future sync acknowledgement.
enum NoteStatus { exportPending, localSaved, exportFailed }

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
    this.vaultDirectory,
    this._clock,
    this._createId,
    this._filePublisher,
  );

  final Database _database;
  final Directory vaultDirectory;
  final DateTime Function() _clock;
  final String Function() _createId;
  final NoteFilePublisher _filePublisher;
  Future<void> _mutations = Future.value();

  static Future<NoteWorkspace> open({
    required Directory localDirectory,
    required Directory vaultDirectory,
    DateTime Function()? clock,
    String Function()? createId,
    NoteFilePublisher? filePublisher,
  }) async {
    if (!await vaultDirectory.exists()) {
      throw const FileSystemException('所选笔记库不存在，请重新选择。');
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
    if (!database.select('PRAGMA table_info(notes)').any((row) => row['name'] == 'title_collision')) {
      database.execute('ALTER TABLE notes ADD COLUMN title_collision INTEGER NOT NULL DEFAULT 0');
    }
    final workspace = NoteWorkspace._(
      database,
      Directory(await vaultDirectory.resolveSymbolicLinks()),
      clock ?? DateTime.now,
      createId ?? _randomId,
      filePublisher ?? AtomicNoteFilePublisher(),
    );
    for (final note in workspace.notes) {
      if (note.status == NoteStatus.exportPending) {
        await workspace.retryNoteExport(note.id);
      }
    }
    return workspace;
  }

  List<WorkspaceNote> get notes => List.unmodifiable(
    _database
        .select(
          'SELECT * FROM notes WHERE vault = ? ORDER BY created_at DESC, id DESC',
          [vaultDirectory.path],
        )
        .map(_noteFromRow),
  );

  /// Find durable originals without requiring an exported note or a network.
  /// An empty query returns recent records in the same order as [notes].
  List<WorkspaceNote> search(String query) {
    final keyword = query.trim().toLowerCase();
    return List.unmodifiable(notes.where((note) =>
        keyword.isEmpty ||
        note.title.toLowerCase().contains(keyword) ||
        note.text.toLowerCase().contains(keyword)));
  }

  Future<WorkspaceNote> captureText({
    required String title,
    required String text,
    List<String> semanticTitleCandidates = const [],
  }) => _mutate(() async {
    if (text.trim().isEmpty) throw ArgumentError('请输入要保存的文字。');
    final naming = await _chooseTitle(title, semanticTitleCandidates);
    final safeTitle = naming.title;
    final id = _createId();
    final now = _clock();
    final note = WorkspaceNote(
      id: id,
      title: safeTitle,
      text: text,
      createdAt: now,
      modifiedAt: now,
      notePath: p.join(vaultDirectory.path, '$safeTitle.md'),
      sourcePath: p.join(
        vaultDirectory.path,
        'attachments',
        'note-agent',
        '$id.txt',
      ),
      status: NoteStatus.exportPending,
      titleCollision: naming.collision,
    );
    _database.execute(
      '''INSERT INTO notes
      (id, vault, title, body, created_at, modified_at, note_path, source_path, status, title_collision)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        vaultDirectory.path,
        safeTitle,
        text,
        now.toIso8601String(),
        now.toIso8601String(),
        note.notePath,
        note.sourcePath,
        NoteStatus.exportPending.name,
        naming.collision ? 1 : 0,
      ],
    );
    return retryNoteExport(id);
  });

  /// Candidates are semantic alternatives supplied by the organizing service.
  /// This workspace performs no AI calls and invents no semantic alternatives.
  Future<({String title, bool collision})> _chooseTitle(
    String title, List<String> alternatives, {String? excludingId}
  ) async {
    final preferred = _safeTitle(title);
    final occupied = <String>{
      for (final note in notes)
        if (note.id != excludingId) note.title.toLowerCase(),
    };
    await for (final entity in vaultDirectory.list(followLinks: false)) {
      if (p.extension(entity.path).toLowerCase() == '.md') {
        occupied.add(p.basenameWithoutExtension(entity.path).toLowerCase());
      }
    }
    if (excludingId != null) {
      final current = notes.firstWhere((note) => note.id == excludingId);
      occupied.remove(current.title.toLowerCase());
    }
    for (final candidate in [preferred, ...alternatives.map(_safeTitle)]) {
      if (!occupied.contains(candidate.toLowerCase())) {
        return (title: candidate, collision: false);
      }
    }
    var number = 2;
    while (occupied.contains('$preferred（$number）'.toLowerCase())) {
      number++;
    }
    return (title: '$preferred（$number）', collision: true);
  }

  String _safeTitle(String title) {
    var safe = title.trim().replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty || safe == '.' || safe == '..') {
      throw ArgumentError('请输入可用的笔记标题。');
    }
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', caseSensitive: false).hasMatch(safe)) {
      safe = '$safe 笔记';
    }
    return safe;
  }

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Retries publication of an existing durable capture without collecting again.
  Future<WorkspaceNote> retryNoteExport(String id) async {
    final note = notes.firstWhere((note) => note.id == id);
    try {
      final staging = Directory(
        p.join(vaultDirectory.path, '.note-agent-staging', note.id),
      );
      await _prepareDirectory(staging);
      await _prepareDirectory(File(note.sourcePath).parent);
      await _filePublisher.publish(
        destination: File(note.sourcePath),
        staging: File(p.join(staging.path, 'source.txt')),
        text: note.text,
      );
      await _filePublisher.publish(
        destination: File(note.notePath),
        staging: File(p.join(staging.path, 'note.md')),
        text: _markdown(note),
      );
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // Publication has committed; stale private staging can be removed later.
      }
      _database.execute(
        'UPDATE notes SET status = ?, error = NULL WHERE id = ?',
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

  Future<void> _prepareDirectory(Directory directory) async {
    var current = vaultDirectory.path;
    for (final part in p.split(p.relative(directory.path, from: current))) {
      if (part == '.') continue;
      current = p.join(current, part);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw FileSystemException('写入目录不能指向笔记库以外的位置。', current);
      }
      if (type == FileSystemEntityType.notFound) {
        await Directory(current).create();
      }
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw FileSystemException('笔记库写入位置不是目录。', current);
      }
    }
  }

  Future<void> close() async => _database.close();

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
