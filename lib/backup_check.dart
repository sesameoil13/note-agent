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

bool _within(String child, String parent) =>
    p.equals(child, parent) || p.isWithin(parent, child);

Future<Map<String, int>> _inventory(Directory dir) async {
  final files = <String, int>{};
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      files[p.posix.joinAll(p.split(p.relative(entity.path, from: dir.path)))] =
          await entity.length();
    }
  }
  return files;
}

/// [syncVault] is the folder this App writes to; neither side may overlap it.
Future<BackupComparison> compareVaultBackup({
  required Directory oldVault,
  required Directory backup,
  Directory? syncVault,
}) async {
  if (!await oldVault.exists() || !await backup.exists()) {
    throw const BackupCheckRefused('无法读取所选文件夹，请重新选择。');
  }
  Future<String> real(Directory dir) async =>
      p.canonicalize(await dir.resolveSymbolicLinks());
  final oldPath = await real(oldVault);
  final backupPath = await real(backup);
  if (_within(backupPath, oldPath) || _within(oldPath, backupPath)) {
    throw const BackupCheckRefused('备份必须位于旧库之外的独立位置。');
  }
  if (syncVault != null) {
    final sync = await syncVault.exists()
        ? await real(syncVault)
        : p.canonicalize(syncVault.path);
    if (_within(oldPath, sync) || _within(sync, oldPath)) {
      throw const BackupCheckRefused('所选旧库与当前同步库重叠，请选择旧库本身。');
    }
    if (_within(backupPath, sync) || _within(sync, backupPath)) {
      throw const BackupCheckRefused('备份不能放在当前同步库里，否则会被同步或改写。');
    }
  }
  final old = await _inventory(oldVault);
  if (old.isEmpty) {
    throw const BackupCheckRefused('所选旧库中没有文件，无法核对备份。');
  }
  final copy = await _inventory(backup);
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
