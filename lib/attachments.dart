import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'sync_policy.dart';
import 'vault_storage.dart';

enum AttachmentStatus {
  exportPending,
  localSaved,
  retainedLocal,
  exceedsFileLimit,
  exportFailed,
}

class WorkspaceAttachment {
  const WorkspaceAttachment({
    required this.id,
    required this.noteId,
    required this.originalName,
    required this.originalPath,
    required this.originalByteLength,
    required this.sourcePath,
    required this.status,
    this.error,
  });

  final String id;
  final String noteId;
  final String originalName;
  final String originalPath;
  final int originalByteLength;
  final String sourcePath;
  final AttachmentStatus status;
  final String? error;
}

/// Internal source durability and publication, used only through NoteWorkspace.
class WorkspaceAttachments {
  WorkspaceAttachments(this.database, this.local, this.vault, this.createId) {
    database.execute('''CREATE TABLE IF NOT EXISTS attachments (
      id TEXT PRIMARY KEY, note_id TEXT NOT NULL, vault TEXT NOT NULL,
      original_name TEXT NOT NULL, original_path TEXT NOT NULL,
      original_bytes INTEGER NOT NULL, source_path TEXT NOT NULL,
      status TEXT NOT NULL, error TEXT, source_entry TEXT NOT NULL DEFAULT ''
    )''');
  }

  final Database database;
  final Directory local;
  final VaultStorage vault;
  final String Function() createId;

  List<WorkspaceAttachment> get attachments => List.unmodifiable(
    database.select('SELECT * FROM attachments WHERE vault = ? ORDER BY id', [vault.identity])
      .map((row) => WorkspaceAttachment(
        id: row['id'] as String,
        noteId: row['note_id'] as String,
        originalName: row['original_name'] as String,
        originalPath: row['original_path'] as String,
        originalByteLength: row['original_bytes'] as int,
        sourcePath: row['source_path'] as String,
        status: AttachmentStatus.values.byName(row['status'] as String),
        error: row['error'] as String?,
      )),
  );

  Future<WorkspaceAttachment> attach(String noteId, File original) async {
    if (database.select('SELECT id FROM notes WHERE id = ? AND vault = ?', [noteId, vault.identity]).isEmpty) {
      throw ArgumentError('请先保存要添加来源的笔记。');
    }
    final id = createId();
    final name = p.basename(original.path).replaceAll(RegExp(r'[\r\n\[\]()]'), '_');
    final destination = File(p.join(local.path, 'originals', id, name));
    await destination.parent.create(recursive: true);
    if (await destination.exists()) throw StateError('来源身份已存在，请重新选择。');
    final staging = File('${destination.path}.pending');
    await original.copy(staging.path);
    final handle = await staging.open(mode: FileMode.append);
    await handle.flush();
    await handle.close();
    await staging.rename(destination.path);
    final bytes = await destination.length();
    final status = bytes > ObsidianSyncStandard.maximumFileBytes
      ? AttachmentStatus.exceedsFileLimit : AttachmentStatus.exportPending;
    database.execute('''INSERT INTO attachments
      (id, note_id, vault, original_name, original_path, original_bytes, source_path, status)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)''', [
      id, noteId, vault.identity, name, destination.path, bytes,
      vault.reference('attachments/note-agent/$id/$name'), status.name,
    ]);
    final result = attachments.firstWhere((item) => item.id == id);
    if (status == AttachmentStatus.exceedsFileLimit) {
      await writeEntry(result, '$name（仅本机保留，超过 Standard 单文件 5 MB）');
    }
    return attachments.firstWhere((item) => item.id == id);
  }

  Future<void> writeEntry(WorkspaceAttachment attachment, String entry) async {
    try {
      final row = database.select('SELECT note_path FROM notes WHERE id = ? AND vault = ?', [attachment.noteId, vault.identity]).single;
      final path = vault.relativePath(row['note_path'] as String);
      final text = await vault.readText(path);
      final old = database.select('SELECT source_entry FROM attachments WHERE id = ?', [attachment.id]).single['source_entry'] as String;
      String updated;
      if (old.isNotEmpty) {
        if (!text.contains('\n\n$old\n\n')) throw const FileSystemException('来源已在其他位置修改，请核对后重试。');
        updated = text.replaceFirst('\n\n$old\n\n', '\n\n$entry\n\n');
      } else {
        const anchor = '## 来源\n\n';
        if (anchor.allMatches(text).length != 1) throw const FileSystemException('未找到唯一的来源位置，请核对笔记。');
        updated = text.replaceFirst(anchor, '$anchor$entry\n\n');
      }
      await vault.replaceText(path, text, updated, 'attachment-${attachment.id}');
      database.execute('UPDATE attachments SET source_entry = ?, error = NULL WHERE id = ?', [entry, attachment.id]);
    } on FileSystemException catch (error) {
      database.execute('UPDATE attachments SET error = ? WHERE id = ?', [error.message, attachment.id]);
    }
  }
}
