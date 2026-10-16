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
    required this.vaultCopyPublished,
    required this.originalPublished,
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
  final bool vaultCopyPublished;
  final bool originalPublished;

  /// A refused oversized original was never submitted to vault publication.
  /// A failed publication of an eligible file may already have committed.
  bool get hasLocalOnlyOriginal =>
      originalByteLength > ObsidianSyncStandard.maximumFileBytes &&
      !originalPublished;
}

/// Internal source durability and publication, used only through NoteWorkspace.
class WorkspaceAttachments {
  WorkspaceAttachments(this.database, this.local, this.vault, this.createId) {
    database.execute('''CREATE TABLE IF NOT EXISTS attachments (
      id TEXT PRIMARY KEY, note_id TEXT NOT NULL, vault TEXT NOT NULL,
      original_name TEXT NOT NULL, original_path TEXT NOT NULL,
      original_bytes INTEGER NOT NULL, source_path TEXT NOT NULL,
      status TEXT NOT NULL, error TEXT, source_entry TEXT NOT NULL DEFAULT '',
      copy_path TEXT, copy_name TEXT, entry_before TEXT, entry_after TEXT, entry_target TEXT,
      vault_copy_published INTEGER NOT NULL DEFAULT 0, original_published INTEGER NOT NULL DEFAULT 0
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
            vaultCopyPublished: row['vault_copy_published'] == 1,
            originalPublished: row['original_published'] == 1,
          ),
        ),
  );

  /// An audio collection already owns its durable private original. Reuse it
  /// and the publication facts rather than making a second copy or identity.
  void adoptAudio({
    required String id,
    required String noteId,
    required String name,
    required String originalPath,
    required int bytes,
    required String sourcePath,
    required bool published,
    required String sourceEntry,
    String? error,
  }) {
    database.execute(
      '''INSERT OR IGNORE INTO attachments
      (id,note_id,vault,original_name,original_path,original_bytes,source_path,status,source_entry,
       vault_copy_published,original_published,error) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        id,
        noteId,
        vault.identity,
        name,
        originalPath,
        bytes,
        sourcePath,
        (published
                ? AttachmentStatus.localSaved
                : bytes > ObsidianSyncStandard.maximumFileBytes
                ? AttachmentStatus.exceedsFileLimit
                : AttachmentStatus.exportFailed)
            .name,
        sourceEntry,
        published ? 1 : 0,
        published ? 1 : 0,
        error,
      ],
    );
  }

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
    if (attachment.vaultCopyPublished ||
        attachment.originalByteLength <=
            ObsidianSyncStandard.maximumFileBytes) {
      throw ArgumentError('此来源已有笔记库写入尝试；仅保留本机不会撤回可能已写入的文件，请先核对或重试。');
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
    if (attachment.originalPublished ||
        attachment.originalByteLength <=
            ObsidianSyncStandard.maximumFileBytes) {
      throw ArgumentError('此操作用于超过 5 MB 且仅本机保留的原件；不会撤回可能已写入的文件。');
    }
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
      'UPDATE attachments SET copy_path = ?, copy_name = ?, source_path = ?, status = ?, vault_copy_published = 0, error = NULL WHERE id = ?',
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
        if (pending != null) {
          await writeEntry(attachment, pending);
          final updated = attachments.firstWhere(
            (item) => item.id == attachment.id,
          );
          if (updated.vaultCopyPublished &&
              updated.error == null &&
              updated.status == AttachmentStatus.exportFailed) {
            database.execute('UPDATE attachments SET status = ? WHERE id = ?', [
              AttachmentStatus.localSaved.name,
              attachment.id,
            ]);
          }
        }
      }
    }
  }

  Future<WorkspaceAttachment> export(String id) async {
    final attachment = attachments.firstWhere((item) => item.id == id);
    database.execute('UPDATE attachments SET status = ? WHERE id = ?', [
      AttachmentStatus.exportPending.name,
      id,
    ]);
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
      database.execute(
        'UPDATE attachments SET vault_copy_published = 1, original_published = ? WHERE id = ?',
        [
          attachment.copyPath == null
              ? 1
              : (attachment.originalPublished ? 1 : 0),
          id,
        ],
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
        _entryCommitted(
          attachment,
          rowEntry['entry_target'] as String,
          rowEntry['entry_after'] as String,
        );
        rowEntry = database.select('SELECT * FROM attachments WHERE id = ?', [
          attachment.id,
        ]).single;
      }
      final old = rowEntry['source_entry'] as String;
      if (old == entry) return;
      final text = await vault.readText(path);
      final updated = _withEntry(text, old, entry);
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
      _entryCommitted(attachment, entry, updated);
    } on FileSystemException catch (error) {
      database.execute('UPDATE attachments SET error = ? WHERE id = ?', [
        error.message,
        attachment.id,
      ]);
    }
  }

  void _entryCommitted(
    WorkspaceAttachment attachment,
    String entry,
    String text,
  ) {
    database.execute('BEGIN IMMEDIATE');
    try {
      database.execute(
        'UPDATE attachments SET source_entry = ?, entry_before = NULL, entry_after = NULL, entry_target = NULL, error = NULL WHERE id = ?',
        [entry, attachment.id],
      );
      noteContentsChanged(attachment.noteId, text);
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Called inside the transaction that commits an owned rename/source write.
  /// The new note text is already published. Rebase only our source delta;
  /// never replay the journal's older body or modification line over it.
  void noteContentsChanged(String noteId, String renamedText) {
    final pending = database.select(
      'SELECT * FROM attachments WHERE vault = ? AND note_id = ? AND entry_before IS NOT NULL',
      [vault.identity, noteId],
    );
    for (final row in pending) {
      try {
        final target = row['entry_target'] as String;
        final updated = _withEntry(
          renamedText,
          row['source_entry'] as String,
          target,
          acceptExisting: true,
        );
        database.execute(
          'UPDATE attachments SET entry_before = ?, entry_after = ? WHERE id = ?',
          [renamedText, updated, row['id']],
        );
      } on FileSystemException catch (error) {
        // A genuinely edited/ambiguous source remains pending. The rename
        // succeeds without overwriting those changes or asserting publication.
        database.execute('UPDATE attachments SET error = ? WHERE id = ?', [
          error.message,
          row['id'],
        ]);
      }
    }
  }

  String _withEntry(
    String text,
    String old,
    String entry, {
    bool acceptExisting = false,
  }) {
    const anchor = '## 来源\n\n';
    if (anchor.allMatches(text).length != 1) {
      throw const FileSystemException('未找到唯一的来源位置，请核对笔记。');
    }
    final start = text.indexOf(anchor);
    final date = text.indexOf('\n\n记录：', start + anchor.length);
    if (date < 0) {
      throw const FileSystemException('未找到来源后的记录时间，请核对笔记。');
    }
    final source = '${text.substring(start, date)}\n\n';
    final targetPattern = '\n\n$entry\n\n';
    final targets = targetPattern.allMatches(source).length;
    final oldPattern = '\n\n$old\n\n';
    final oldMatches = old.isEmpty ? 0 : oldPattern.allMatches(source).length;
    if (acceptExisting &&
        targets == 1 &&
        (old.isEmpty || oldMatches == 0 || old == entry)) {
      return text;
    }
    if (targets != 0 || (old.isNotEmpty && oldMatches != 1)) {
      throw const FileSystemException('来源已在其他位置修改，请核对后重试。');
    }
    final updatedSource = old.isEmpty
        ? '${source.substring(0, source.length - 2)}\n\n$entry\n\n'
        : source.replaceFirst(oldPattern, targetPattern);
    return '${text.substring(0, start)}${updatedSource.substring(0, updatedSource.length - 2)}${text.substring(date)}';
  }
}
