import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'note_files.dart';
import 'vault_storage.dart';
export 'vault_storage.dart';
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

  static Future<NoteWorkspace> open({
    required Directory localDirectory,
    Directory? vaultDirectory,
    VaultStorage? vaultStorage,
    DateTime Function()? clock,
    String Function()? createId,
    NoteFilePublisher? filePublisher,
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
    final workspace = NoteWorkspace._(
      database,
      vaultStorage,
      clock ?? DateTime.now,
      createId ?? _randomId,
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
          [vaultStorage.identity],
        )
        .map(_noteFromRow),
  );

  Future<WorkspaceNote> captureText({
    required String title,
    required String text,
  }) async {
    if (text.trim().isEmpty) throw ArgumentError('请输入要保存的文字。');
    final safeTitle = title.trim().replaceAll(
      RegExp(r'[/\\:*?"<>|\x00-\x1f]'),
      ' ',
    );
    if (safeTitle.isEmpty || safeTitle == '.' || safeTitle == '..') {
      throw ArgumentError('请输入可用的笔记标题。');
    }
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
      (id, vault, title, body, created_at, modified_at, note_path, source_path, status)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
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
      ],
    );
    return retryNoteExport(id);
  }

  /// Retries publication of an existing durable capture without collecting again.
  Future<WorkspaceNote> retryNoteExport(String id) async {
    final note = notes.firstWhere((note) => note.id == id);
    try {
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
