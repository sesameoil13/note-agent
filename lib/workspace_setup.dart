import 'package:sqlite3/sqlite3.dart';

import 'connection.dart';

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
  WorkspaceSetupState(
    this.reports,
    this.remoteSlotConsentAt, [
    this.backupVerifiedAt,
  ]);
  final Map<SetupCheck, DateTime> reports;
  final DateTime? remoteSlotConsentAt;

  /// Set only by the App's own read-only comparison of two folders.
  final DateTime? backupVerifiedAt;
  bool isReported(SetupCheck check) => reports.containsKey(check);
  bool get backupReady =>
      (backupVerifiedAt != null || isReported(SetupCheck.backupComplete)) &&
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
  static const _verified = 'backupVerifiedByApp';

  WorkspaceSetupState get state {
    final entries = <String, DateTime>{
      for (final row in database.select(
        'SELECT item,reported_at FROM setup_reports WHERE vault = ?',
        [vault],
      ))
        row['item'] as String: DateTime.parse(row['reported_at'] as String),
    };
    return WorkspaceSetupState(
      Map.unmodifiable({
        for (final check in SetupCheck.values)
          if (entries.containsKey(check.name)) check: entries[check.name]!,
      }),
      entries[_consent],
      entries[_verified],
    );
  }

  void _save(String item) => database.execute(
    'INSERT OR REPLACE INTO setup_reports(vault,item,reported_at) VALUES (?,?,?)',
    [vault, item, clock().toIso8601String()],
  );

  void report(SetupCheck check, bool checked) {
    if (checked &&
        check == SetupCheck.remoteSlotSwitched &&
        state.remoteSlotConsentAt == null) {
      throw StateError('请先核对备份并单独确认远程名额切换。');
    }
    if (checked) {
      _save(check.name);
    } else {
      database.execute(
        'DELETE FROM setup_reports WHERE vault = ? AND item = ?',
        [vault, check.name],
      );
      if (!state.backupReady) _withdrawConsent();
    }
  }

  void _withdrawConsent() => database.execute(
    'DELETE FROM setup_reports WHERE vault = ? AND item IN (?,?)',
    [vault, _consent, SetupCheck.remoteSlotSwitched.name],
  );

  /// A failed comparison invalidates both earlier evidence and the consent.
  void recordBackupCheck(bool complete) {
    if (complete) {
      _save(_verified);
      return;
    }
    database.execute(
      'DELETE FROM setup_reports WHERE vault = ? AND item IN (?,?)',
      [vault, _verified, SetupCheck.backupComplete.name],
    );
    _withdrawConsent();
  }

  void consent() {
    if (!state.backupReady) throw StateError('请先核对完整备份和保留的本地导入副本。');
    _save(_consent);
  }

  void clear() =>
      database.execute('DELETE FROM setup_reports WHERE vault = ?', [vault]);
}

enum SetupStep {
  aiConnection,
  devicePairing,
  vault,
  permissions,
  obsidian,
  backup,
}

/// Who stands behind a step. Only [appVerified] is the App's own evidence;
/// [userReported] is the user's word about another app or the system.
enum SetupEvidence { notDone, needsAttention, userReported, appVerified }

class SetupStepStatus {
  const SetupStepStatus(this.step, this.evidence, this.detail);
  final SetupStep step;
  final SetupEvidence evidence;
  final String detail;
}

const _obsidianChecks = [
  SetupCheck.correctVaultOpened,
  SetupCheck.standardPlan,
  SetupCheck.otherFileTypes,
  SetupCheck.hiddenProperties,
];

/// Summarises the guide without claiming anything the App cannot verify.
List<SetupStepStatus> describeSetup({
  required WorkspaceSetupState? setup,
  required WorkspaceConnectionState connection,
  required WorkspacePairingState pairing,
  required String? vaultName,
  String? vaultAuthorizationError,
}) {
  bool has(SetupCheck c) => setup?.isReported(c) ?? false;
  final obsidianDone = _obsidianChecks.where(has).length;
  return [
    connection.connectionVerified
        ? const SetupStepStatus(
            SetupStep.aiConnection,
            SetupEvidence.appVerified,
            'App 已检测 OpenRouter 连接',
          )
        : connection.hasKey
        ? SetupStepStatus(
            SetupStep.aiConnection,
            SetupEvidence.needsAttention,
            connection.message,
          )
        : const SetupStepStatus(
            SetupStep.aiConnection,
            SetupEvidence.notDone,
            '尚未连接 OpenRouter，或从原设备配对获得',
          ),
    pairing.role != null
        ? SetupStepStatus(
            SetupStep.devicePairing,
            SetupEvidence.appVerified,
            '本机已登记为${pairing.role == 'owner' ? '原设备' : '已配对设备'}'
            '${pairing.deviceName == null ? '' : '：${pairing.deviceName}'}',
          )
        : SetupStepStatus(
            SetupStep.devicePairing,
            SetupEvidence.notDone,
            pairing.message,
          ),
    vaultAuthorizationError != null
        ? SetupStepStatus(
            SetupStep.vault,
            SetupEvidence.needsAttention,
            vaultAuthorizationError,
          )
        : vaultName != null
        ? SetupStepStatus(
            SetupStep.vault,
            SetupEvidence.appVerified,
            'App 已获得本地库授权：$vaultName',
          )
        : const SetupStepStatus(
            SetupStep.vault,
            SetupEvidence.notDone,
            '尚未选择本地笔记库',
          ),
    has(SetupCheck.microphoneTested) && has(SetupCheck.notificationsTested)
        ? const SetupStepStatus(
            SetupStep.permissions,
            SetupEvidence.userReported,
            '你已实际测试录音与提醒；权限仍由系统决定',
          )
        : const SetupStepStatus(
            SetupStep.permissions,
            SetupEvidence.notDone,
            '录音与通知权限由系统在使用时请求',
          ),
    obsidianDone == _obsidianChecks.length
        ? const SetupStepStatus(
            SetupStep.obsidian,
            SetupEvidence.userReported,
            '你已核对 4 / 4 项；App 无法验证 Sync 实际到达',
          )
        : SetupStepStatus(
            SetupStep.obsidian,
            SetupEvidence.notDone,
            '已核对 $obsidianDone / ${_obsidianChecks.length} 项',
          ),
    setup?.backupVerifiedAt != null
        ? const SetupStepStatus(
            SetupStep.backup,
            SetupEvidence.appVerified,
            'App 已只读比对旧库与备份，文件齐全且大小一致',
          )
        : has(SetupCheck.backupComplete)
        ? const SetupStepStatus(
            SetupStep.backup,
            SetupEvidence.userReported,
            '你已核对备份；App 未比对文件',
          )
        : const SetupStepStatus(
            SetupStep.backup,
            SetupEvidence.notDone,
            '没有旧库可跳过；有旧库时先核对完整备份',
          ),
  ];
}
