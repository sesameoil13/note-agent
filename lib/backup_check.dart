import 'dart:io';

import 'package:path/path.dart' as p;

/// The App refuses a comparison that cannot prove an independent backup.
class BackupCheckRefused implements Exception {
  const BackupCheckRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Read-only comparison between a user-chosen old vault and a user-chosen
/// backup folder. Nothing is copied, renamed, or deleted.
class BackupComparison {
  const BackupComparison({
    required this.oldFileCount,
    required this.oldBytes,
    required this.backupFileCount,
    required this.backupBytes,
    required this.includesObsidianConfig,
    required this.missing,
    required this.sizeMismatched,
  });
  final int oldFileCount;
  final int oldBytes;
  final int backupFileCount;
  final int backupBytes;
  final bool includesObsidianConfig;
  final List<String> missing;
  final List<String> sizeMismatched;
  bool get complete => missing.isEmpty && sizeMismatched.isEmpty;
}

/// Where a folder sits, so overlap can be refused before anything is listed.
/// Locations in different namespaces (filesystem vs. a SAF volume) never
/// overlap.
class FolderLocation {
  const FolderLocation(this.namespace, this.segments);
  final String namespace;
  final List<String> segments;
  bool within(FolderLocation parent) =>
      namespace == parent.namespace &&
      segments.length >= parent.segments.length &&
      Iterable<int>.generate(parent.segments.length)
          .every((i) => segments[i] == parent.segments[i]);
  bool overlaps(FolderLocation other) => within(other) || other.within(this);

  /// A SAF tree such as `content://com.android.externalstorage.documents/tree/primary%3ADocs%2FVault`.
  /// External-storage document ids are `volume:relative/path`; other providers'
  /// ids are opaque, so only the identical tree is detected as overlapping.
  static FolderLocation? ofTree(String treeUri) {
    final uri = Uri.tryParse(treeUri);
    if (uri == null || uri.scheme != 'content') return null;
    final parts = uri.pathSegments;
    final index = parts.indexOf('tree');
    if (index < 0 || index + 1 >= parts.length) return null;
    final id = parts[index + 1];
    if (uri.authority == 'com.android.externalstorage.documents' &&
        id.contains(':')) {
      final colon = id.indexOf(':');
      return FolderLocation(
        'saf:${uri.authority}:${id.substring(0, colon)}',
        id.substring(colon + 1).split('/').where((s) => s.isNotEmpty).toList(),
      );
    }
    return FolderLocation('saf:${uri.authority}', [id]);
  }
}

/// A folder picked for one read-only comparison. Implementations only read.
abstract interface class ReadOnlyFolder {
  /// Throws [BackupCheckRefused] when the folder cannot be read.
  Future<FolderLocation> locate();

  /// Relative POSIX path (dot-folders included) to size in bytes.
  Future<Map<String, int>> inventory();
}

/// A filesystem folder (macOS, Windows, tests).
class DirectoryFolder implements ReadOnlyFolder {
  DirectoryFolder(this.directory);
  final Directory directory;
  @override
  Future<FolderLocation> locate() async {
    if (!await directory.exists()) {
      throw const BackupCheckRefused('无法读取所选文件夹，请重新选择。');
    }
    return FolderLocation(
      'file',
      p.split(p.canonicalize(await directory.resolveSymbolicLinks())),
    );
  }

  @override
  Future<Map<String, int>> inventory() async {
    final files = <String, int>{};
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        files[p.posix.joinAll(
          p.split(p.relative(entity.path, from: directory.path)),
        )] = await entity
            .length();
      }
    }
    return files;
  }
}

/// [syncVault] is where this App writes; neither side may overlap it.
Future<BackupComparison> compareVaultBackup({
  required ReadOnlyFolder oldVault,
  required ReadOnlyFolder backup,
  FolderLocation? syncVault,
}) async {
  final oldPath = await oldVault.locate();
  final backupPath = await backup.locate();
  if (backupPath.overlaps(oldPath)) {
    throw const BackupCheckRefused('备份必须位于旧库之外的独立位置。');
  }
  if (syncVault != null) {
    if (oldPath.overlaps(syncVault)) {
      throw const BackupCheckRefused('所选旧库与当前同步库重叠，请选择旧库本身。');
    }
    if (backupPath.overlaps(syncVault)) {
      throw const BackupCheckRefused('备份不能放在当前同步库里，否则会被同步或改写。');
    }
  }
  final old = await oldVault.inventory();
  if (old.isEmpty) {
    throw const BackupCheckRefused('所选旧库中没有文件，无法核对备份。');
  }
  final copy = await backup.inventory();
  final missing = [
    for (final path in old.keys)
      if (!copy.containsKey(path)) path,
  ]..sort();
  final mismatched = [
    for (final entry in old.entries)
      if (copy.containsKey(entry.key) && copy[entry.key] != entry.value)
        entry.key,
  ]..sort();
  bool config(Map<String, int> files) =>
      files.keys.any((path) => path.startsWith('.obsidian/'));
  return BackupComparison(
    oldFileCount: old.length,
    oldBytes: old.values.fold(0, (a, b) => a + b),
    backupFileCount: copy.length,
    backupBytes: copy.values.fold(0, (a, b) => a + b),
    includesObsidianConfig: config(old) && config(copy),
    missing: missing,
    sizeMismatched: mismatched,
  );
}
