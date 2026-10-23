import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  final t = DateTime.utc(2026, 10, 23);
  WorkspaceSetupState reported(Set<SetupCheck> checks, {DateTime? verified}) =>
      WorkspaceSetupState({for (final c in checks) c: t}, null, verified);

  SetupStepStatus step(List<SetupStepStatus> steps, SetupStep id) =>
      steps.singleWhere((s) => s.step == id);

  test('a fresh install shows every step as not done, never as done', () {
    final steps = describeSetup(
      setup: null,
      connection: const WorkspaceConnectionState(),
      pairing: const WorkspacePairingState(),
      vaultName: null,
    );
    expect(steps.map((s) => s.step), SetupStep.values);
    expect(steps.map((s) => s.evidence).toSet(), {SetupEvidence.notDone});
  });

  test('connection, pairing and vault are App-verified only when the App holds proof', () {
    final steps = describeSetup(
      setup: reported({}),
      connection: const WorkspaceConnectionState(
        hasKey: true,
        connectionVerified: true,
      ),
      pairing: const WorkspacePairingState(role: 'owner', deviceName: 'Mac'),
      vaultName: '新库',
    );
    expect(
      step(steps, SetupStep.aiConnection).evidence,
      SetupEvidence.appVerified,
    );
    expect(
      step(steps, SetupStep.devicePairing).evidence,
      SetupEvidence.appVerified,
    );
    expect(step(steps, SetupStep.vault).evidence, SetupEvidence.appVerified);
    expect(step(steps, SetupStep.vault).detail, contains('新库'));
  });

  test('a saved but unchecked or failed key, or an expired vault grant, needs attention', () {
    final steps = describeSetup(
      setup: null,
      connection: const WorkspaceConnectionState(
        hasKey: true,
        message: 'OpenRouter Key 已失效，请更新。',
      ),
      pairing: const WorkspacePairingState(),
      vaultName: null,
      vaultAuthorizationError: '笔记库授权已失效，请重新选择同一目录。',
    );
    expect(
      step(steps, SetupStep.aiConnection).evidence,
      SetupEvidence.needsAttention,
    );
    expect(step(steps, SetupStep.aiConnection).detail, contains('已失效'));
    expect(step(steps, SetupStep.vault).evidence, SetupEvidence.needsAttention);
  });

  test('Obsidian Sync and permissions are at most user-reported, even when every box is checked', () {
    final steps = describeSetup(
      setup: reported(SetupCheck.values.toSet()),
      connection: const WorkspaceConnectionState(),
      pairing: const WorkspacePairingState(),
      vaultName: '新库',
    );
    expect(
      step(steps, SetupStep.permissions).evidence,
      SetupEvidence.userReported,
    );
    expect(
      step(steps, SetupStep.obsidian).evidence,
      SetupEvidence.userReported,
    );
    expect(step(steps, SetupStep.obsidian).detail, contains('App 无法验证'));
    expect(step(steps, SetupStep.backup).evidence, SetupEvidence.userReported);
  });

  test('partially checked Obsidian items are not reported as done', () {
    final steps = describeSetup(
      setup: reported({SetupCheck.standardPlan, SetupCheck.hiddenProperties}),
      connection: const WorkspaceConnectionState(),
      pairing: const WorkspacePairingState(),
      vaultName: '新库',
    );
    expect(step(steps, SetupStep.obsidian).evidence, SetupEvidence.notDone);
    expect(step(steps, SetupStep.obsidian).detail, contains('2 / 4'));
  });

  test(
    'the backup is App-verified only after the App compared the folders',
    () {
      final steps = describeSetup(
        setup: reported({SetupCheck.localImportCopyRetained}, verified: t),
        connection: const WorkspaceConnectionState(),
        pairing: const WorkspacePairingState(),
        vaultName: '新库',
      );
      expect(step(steps, SetupStep.backup).evidence, SetupEvidence.appVerified);
    },
  );
}
