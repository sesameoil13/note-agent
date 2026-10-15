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
    this.copyName,
    this.copyPath,
  });

  final String id;
  final String noteId;
  final String originalName;
  final String originalPath;
  final int originalByteLength;
  final String sourcePath;
  final AttachmentStatus status;
  final String? error;
  final String? copyName;
  final String? copyPath;
  bool get hasLocalOnlyOriginal =>
      copyPath != null || status != AttachmentStatus.localSaved;
}

/// Internal source durability and publication, used only through NoteWorkspace.
class WorkspaceAttachments {
  WorkspaceAttachments(this.database, this.local, this.vault, this.createId) {
    database.execute('''CREATE TABLE IF NOT EXISTS attachments (
      id TEXT PRIMARY KEY, note_id TEXT NOT NULL, vault TEXT NOT NULL,
      original_name TEXT NOT NULL, original_path TEXT NOT NULL,
      original_bytes INTEGER NOT NULL, source_path TEXT NOT NULL,
      status TEXT NOT NULL, error TEXT, source_entry TEXT NOT NULL DEFAULT '',
      copy_path TEXT, copy_name TEXT, entry_before TEXT, entry_after TEXT, entry_target TEXT
    )''');
  }

  final Database database;
  final Directory local;
  final VaultStorage vault;
  final String Function() createId;

  List<WorkspaceAttachment> get attachments => List.unmodifiable(
    database
        .select('SELECT * FROM attachments WHERE vault = ? ORDER BY id', [
          vault.identity,
        ])
        .map(
          (row) => WorkspaceAttachment(
            id: row['id'] as String,
            noteId: row['note_id'] as String,
            originalName: row['original_name'] as String,
            originalPath: row['original_path'] as String,
            originalByteLength: row['original_bytes'] as int,
            sourcePath: row['source_path'] as String,
            status: AttachmentStatus.values.byName(row['status'] as String),
            error: row['error'] as String?,
            copyName: row['copy_name'] as String?,
            copyPath: row['copy_path'] as String?,
          ),
        ),
  );

  Future<WorkspaceAttachment> attach(String noteId, File original) async {
    if (database.select('SELECT id FROM notes WHERE id = ? AND vault = ?', [
      noteId,
      vault.identity,
    ]).isEmpty) {
      throw ArgumentError('请先保存要添加来源的笔记。');
    }
    final id = createId();
    final name = p
        .basename(original.path)
        .replaceAll(RegExp(r'[\r\n\[\]()]'), '_');
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
        ? AttachmentStatus.exceedsFileLimit
        : AttachmentStatus.exportPending;
    database.execute(
      '''INSERT INTO attachments
      (id, note_id, vault, original_name, original_path, original_bytes, source_path, status)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        noteId,
        vault.identity,
        name,
        destination.path,
        bytes,
        vault.reference('attachments/note-agent/$id/$name'),
        status.name,
      ],
    );
    final result = attachments.firstWhere((item) => item.id == id);
    if (status == AttachmentStatus.exceedsFileLimit) {
      await writeEntry(result, '$name（仅本机保留，超过 Standard 单文件 5 MB）');
    } else {
      await export(id);
    }
    return attachments.firstWhere((item) => item.id == id);
  }

  Future<WorkspaceAttachment> retainLocally(String id) async {
    final attachment = attachments.firstWhere((item) => item.id == id);
    if (attachment.status == AttachmentStatus.localSaved) {
      throw ArgumentError('此来源已写入笔记库；保留本机不会撤回已写入的文件。');
    }
    database.execute('UPDATE attachments SET status = ? WHERE id = ?', [
      AttachmentStatus.retainedLocal.name,
      id,
    ]);
    await writeEntry(attachment, '${attachment.originalName}（仅本机保留，未同步）');
    return attachments.firstWhere((item) => item.id == id);
  }

  Future<WorkspaceAttachment> chooseCopy(String id, File copy) async {
    final attachment = attachments.firstWhere((item) => item.id == id);
    final length = await copy.length();
    if (length > ObsidianSyncStandard.maximumFileBytes ||
        length >= attachment.originalByteLength) {
      throw ArgumentError('请选择小于原件且不超过 5 MB 的精简副本。原件继续保留在本机。');
    }
    final token = createId();
    final name = p.basename(copy.path).replaceAll(RegExp(r'[\r\n\[\]()]'), '_');
    final destination = File(p.join(local.path, 'copies', id, token, name));
    await destination.parent.create(recursive: true);
    await copy.copy(destination.path);
    final handle = await destination.open(mode: FileMode.append);
    await handle.flush();
    await handle.close();
    database.execute(
      'UPDATE attachments SET copy_path = ?, copy_name = ?, source_path = ?, status = ?, error = NULL WHERE id = ?',
      [
        destination.path,
        name,
        vault.reference('attachments/note-agent/$id/$token/$name'),
        AttachmentStatus.exportPending.name,
        id,
      ],
    );
    return export(id);
  }

  Future<void> recover() async {
    for (final attachment in attachments) {
      if (attachment.status == AttachmentStatus.exportPending) {
        await export(attachment.id);
      } else {
        final pending =
            database.select(
                  'SELECT entry_target FROM attachments WHERE id = ?',
                  [attachment.id],
                ).single['entry_target']
                as String?;
        if (pending != null) await writeEntry(attachment, pending);
      }
    }
  }

  Future<WorkspaceAttachment> export(String id) async {
    final attachment = attachments.firstWhere((item) => item.id == id);
    try {
      final source = File(attachment.copyPath ?? attachment.originalPath);
      if (await source.length() > ObsidianSyncStandard.maximumFileBytes) {
        throw const FileSystemException(
          '来源超过 Standard 单文件 5 MB，原件继续保留在本机，未同步。',
        );
      }
      final storage = vault;
      if (storage is! BinaryVaultStorage) {
        throw const FileSystemException('此笔记库尚未接入附件写入，原件已保留在本机。');
      }
      await (storage as BinaryVaultStorage).publishFile(
        vault.relativePath(attachment.sourcePath),
        File(attachment.copyPath ?? attachment.originalPath),
        attachment.id,
      );
      final path = Uri(path: vault.relativePath(attachment.sourcePath))
          .toString();
      final entry = attachment.copyName == null
          ? '[${attachment.originalName}]($path)'
          : '${attachment.originalName}（原件仅本机保留）\n\n[${attachment.copyName}（精简副本）]($path)';
      await writeEntry(attachment, entry);
      final error = attachments.firstWhere((item) => item.id == id).error;
      database.execute('UPDATE attachments SET status = ? WHERE id = ?', [
        (error == null
                ? AttachmentStatus.localSaved
                : AttachmentStatus.exportFailed)
            .name,
        id,
      ]);
    } on FileSystemException catch (error) {
      database.execute(
        'UPDATE attachments SET status = ?, error = ? WHERE id = ?',
        [AttachmentStatus.exportFailed.name, error.message, id],
      );
    }
    return attachments.firstWhere((item) => item.id == id);
  }

  Future<void> writeEntry(WorkspaceAttachment attachment, String entry) async {
    try {
      final row = database.select(
        'SELECT note_path FROM notes WHERE id = ? AND vault = ?',
        [attachment.noteId, vault.identity],
      ).single;
      final path = vault.relativePath(row['note_path'] as String);
      var rowEntry = database.select('SELECT * FROM attachments WHERE id = ?', [
        attachment.id,
      ]).single;
      if (rowEntry['entry_before'] != null) {
        await vault.replaceText(
          path,
          rowEntry['entry_before'] as String,
          rowEntry['entry_after'] as String,
          'attachment-${attachment.id}',
        );
        database.execute(
          'UPDATE attachments SET source_entry = entry_target, entry_before = NULL, entry_after = NULL, entry_target = NULL, error = NULL WHERE id = ?',
          [attachment.id],
        );
        rowEntry = database.select('SELECT * FROM attachments WHERE id = ?', [
          attachment.id,
        ]).single;
      }
      final old = rowEntry['source_entry'] as String;
      if (old == entry) return;
      final text = await vault.readText(path);
      String updated;
      if (old.isNotEmpty) {
        if (!text.contains('\n\n$old\n\n')) {
          throw const FileSystemException('来源已在其他位置修改，请核对后重试。');
        }
        updated = text.replaceFirst('\n\n$old\n\n', '\n\n$entry\n\n');
      } else {
        const anchor = '## 来源\n\n';
        if (anchor.allMatches(text).length != 1) {
          throw const FileSystemException('未找到唯一的来源位置，请核对笔记。');
        }
        final date = text.indexOf(
          '\n\n记录：',
          text.indexOf(anchor) + anchor.length,
        );
        if (date < 0) throw const FileSystemException('未找到来源后的记录时间，请核对笔记。');
        updated = '${text.substring(0, date)}\n\n$entry${text.substring(date)}';
      }
      database.execute(
        'UPDATE attachments SET entry_before = ?, entry_after = ?, entry_target = ? WHERE id = ?',
        [text, updated, entry, attachment.id],
      );
      await vault.replaceText(
        path,
        text,
        updated,
        'attachment-${attachment.id}',
      );
      database.execute(
        'UPDATE attachments SET source_entry = ?, entry_before = NULL, entry_after = NULL, entry_target = NULL, error = NULL WHERE id = ?',
        [entry, attachment.id],
      );
    } on FileSystemException catch (error) {
      database.execute('UPDATE attachments SET error = ? WHERE id = ?', [
        error.message,
        attachment.id,
      ]);
    }
  }
}
