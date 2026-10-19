import 'package:sqlite3/sqlite3.dart';

/// These are the user's reports after checking another app or a backup, never
/// an acknowledgement from Obsidian Sync or the system permission service.
enum SetupCheck {
  standardPlan,
  otherFileTypes,
  hiddenProperties,
  correctVaultOpened,
  microphoneTested,
  notificationsTested,
  backupComplete,
  localImportCopyRetained,
  remoteSlotSwitched,
}

class WorkspaceSetupState {
  WorkspaceSetupState(this.reports, this.remoteSlotConsentAt);
  final Map<SetupCheck, DateTime> reports;
  final DateTime? remoteSlotConsentAt;
  bool isReported(SetupCheck check) => reports.containsKey(check);
  bool get backupReady => isReported(SetupCheck.backupComplete) &&
      isReported(SetupCheck.localImportCopyRetained);
  bool get noteSyncVerified => false;
}

class WorkspaceSetup {
  WorkspaceSetup(this.database, this.vault, this.clock) {
    database.execute('''CREATE TABLE IF NOT EXISTS setup_reports (
      vault TEXT NOT NULL, item TEXT NOT NULL, reported_at TEXT NOT NULL,
      PRIMARY KEY(vault,item))''');
  }
  final Database database;
  final String vault;
  final DateTime Function() clock;
  static const _consent = 'remoteSlotConsent';

  WorkspaceSetupState get state {
    final entries = <String, DateTime>{
      for (final row in database.select(
        'SELECT item,reported_at FROM setup_reports WHERE vault = ?', [vault],
      )) row['item'] as String: DateTime.parse(row['reported_at'] as String),
    };
    return WorkspaceSetupState(Map.unmodifiable({
      for (final check in SetupCheck.values)
        if (entries.containsKey(check.name)) check: entries[check.name]!,
    }), entries[_consent]);
  }

  void _save(String item) => database.execute(
    'INSERT OR REPLACE INTO setup_reports(vault,item,reported_at) VALUES (?,?,?)',
    [vault, item, clock().toIso8601String()],
  );

  void report(SetupCheck check, bool checked) {
    if (checked && check == SetupCheck.remoteSlotSwitched &&
        state.remoteSlotConsentAt == null) {
      throw StateError('请先核对备份并单独确认远程名额切换。');
    }
    if (checked) {
      _save(check.name);
    } else {
      database.execute('DELETE FROM setup_reports WHERE vault = ? AND item = ?',
        [vault, check.name]);
      if (check == SetupCheck.backupComplete ||
          check == SetupCheck.localImportCopyRetained) {
        database.execute('DELETE FROM setup_reports WHERE vault = ? AND item IN (?,?)',
          [vault, _consent, SetupCheck.remoteSlotSwitched.name]);
      }
    }
  }

  void consent() {
    if (!state.backupReady) throw StateError('请先核对完整备份和保留的本地导入副本。');
    _save(_consent);
  }
  void clear() => database.execute('DELETE FROM setup_reports WHERE vault = ?', [vault]);
}
