import 'dart:io';

import 'package:path/path.dart' as p;

import 'note_files.dart';

/// Authorized vault boundary. References are opaque: they may be content URIs,
/// rather than paths that dart:io can open.
abstract interface class VaultStorage {
  String get identity;
  String get displayName;
  String reference(String relativePath);
  String relativePath(String reference);
  Future<bool> exists(String relativePath);
  Future<String> readText(String relativePath);
  Future<void> publishText(
    String relativePath,
    String text,
    String operationId,
  );
  Future<List<String>> listNotePaths();
  Future<void> replaceText(
    String relativePath,
    String expectedText,
    String text,
    String operationId,
  );
  Future<void> deleteText(String relativePath, String expectedText);
}

/// Desktop vault storage, preserving the T01 exclusive publication behavior.
class DirectoryVaultStorage implements VaultStorage {
  DirectoryVaultStorage(this.directory, {NoteFilePublisher? filePublisher})
    : _publisher = filePublisher ?? AtomicNoteFilePublisher();

  final Directory directory;
  final NoteFilePublisher _publisher;

  @override
  String get identity => directory.path;
  @override
  String get displayName => p.basename(directory.path);
  @override
  String reference(String relativePath) =>
      p.join(directory.path, _safe(relativePath));
  @override
  String relativePath(String reference) =>
      _safe(p.relative(reference, from: directory.path));

  String _safe(String relativePath) {
    if (p.isAbsolute(relativePath) ||
        relativePath.isEmpty ||
        p.split(relativePath).any((part) => part == '..' || part == '.')) {
      throw FileSystemException('笔记位置必须位于当前笔记库内。', relativePath);
    }
    return relativePath;
  }

  Future<File> _file(String relativePath, {bool createParents = false}) async {
    final path = reference(relativePath);
    var current = directory.path;
    final parts = p.split(_safe(relativePath));
    for (var index = 0; index < parts.length; index++) {
      current = p.join(current, parts[index]);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw FileSystemException('写入位置不能指向笔记库以外的位置。', current);
      }
      if (index < parts.length - 1) {
        if (type == FileSystemEntityType.notFound && createParents) {
          await Directory(current).create();
        } else if (type != FileSystemEntityType.directory) {
          throw FileSystemException('笔记库写入位置不是目录。', current);
        }
      }
    }
    return File(path);
  }

  @override
  Future<bool> exists(String relativePath) async =>
      (await _file(relativePath)).exists();
  @override
  Future<String> readText(String relativePath) async =>
      (await _file(relativePath)).readAsString();

  @override
  Future<void> publishText(
    String relativePath,
    String text,
    String operationId,
  ) async {
    final destination = await _file(relativePath, createParents: true);
    final staging = await _file(
      p.join(
        '.note-agent-staging',
        _safe(operationId),
        p.basename(relativePath),
      ),
      createParents: true,
    );
    await _publisher.publish(
      destination: destination,
      staging: staging,
      text: text,
    );
    try {
      await staging.parent.delete(recursive: true);
    } on FileSystemException {
      // Publication is committed; leftover private staging is harmless.
    }
  }

  @override
  Future<List<String>> listNotePaths() async {
    final paths = <String>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: directory.path);
      if (entity is File &&
          relative.endsWith('.md') &&
          !p.split(relative).any((part) => part.startsWith('.'))) {
        paths.add(relative);
      }
    }
    return paths..sort();
  }

  @override
  Future<void> replaceText(
    String relativePath,
    String expectedText,
    String text,
    String operationId,
  ) async {
    final destination = await _file(relativePath);
    if (await destination.readAsString() == text) return;
    if (await destination.readAsString() != expectedText) {
      throw FileSystemException('笔记已在其他位置修改，请重新读取后重试。', destination.path);
    }
    final staging = await _file(
      p.join(
        '.note-agent-staging',
        _safe(operationId),
        p.basename(relativePath),
      ),
      createParents: true,
    );
    await staging.writeAsString(text, flush: true);
    if (await destination.readAsString() != expectedText) {
      throw FileSystemException('笔记已在其他位置修改，请重新读取后重试。', destination.path);
    }
    await staging.rename(destination.path);
  }

  @override
  Future<void> deleteText(String relativePath, String expectedText) async {
    final file = await _file(relativePath);
    if (!await file.exists()) return;
    if (await file.readAsString() != expectedText) {
      throw FileSystemException('笔记已在其他位置修改，保留原文件。', file.path);
    }
    await file.delete();
  }
}
