import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

import 'budget_fixture.dart' show BudgetMemoryStore;
import 'pending_notification_fixture.dart';

/// Two paired devices with separate vaults, local SQLite and notification
/// ports, talking to a loopback Workerd + D1 through a proxy whose network
/// can be cut. Note bodies are not transferred (ADR 0001): a test makes a
/// note "arrive" by capturing it on the second device with the same ids.
class TodoSyncFixture {
  late Process _worker;
  late Uri _workerOrigin;
  late HttpServer _proxy;
  late Directory root;
  bool offline = false;
  DateTime now = DateTime(2026, 10, 21, 8);
  final workspaces = <NoteWorkspace>[];
  final ports = <PendingNotifications>[];
  final _stores = <BudgetMemoryStore>[];
  final _counters = <int>[];

  Future<void> start({int devices = 2}) async {
    root = await Directory.systemTemp.createTemp('todo-sync-');
    _worker = await Process.start(
      Platform.environment['NOTE_AGENT_NODE'] ?? 'node',
      ['tools/local-harness.mjs'],
      workingDirectory: 'services/pairing',
    );
    _worker.stderr.transform(utf8.decoder).listen((_) {});
    _workerOrigin = Uri.parse(
      await _worker.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          // Starting the local Worker runtime is slow on Windows CI.
          .timeout(const Duration(seconds: 60)),
    );
    _proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _proxy.listen(_forward);
    for (var i = 0; i < devices; i++) {
      _stores.add(BudgetMemoryStore());
      ports.add(PendingNotifications());
      _counters.add(0);
      await Directory('${root.path}/vault$i').create();
      workspaces.add(await _open(i));
    }
    final owner = workspaces.first.connection;
    await owner.connectAi('sk-or-v1-todo-sync-fixture-only-key');
    await owner.activatePairing(
      setupToken: 'local-test-setup-only',
      deviceName: 'owner',
    );
    for (final w in workspaces.skip(1)) {
      await owner.createPairing();
      await w.connection.joinPairing(owner.pairing.code!, deviceName: 'member');
      await owner.refreshPairing();
      await owner.approvePairing(
        verificationCode: owner.pairing.verificationCode!,
      );
      await w.connection.refreshPairing();
      await owner.refreshPairing();
    }
  }

  Future<void> _forward(HttpRequest r) async {
    if (offline) {
      (await r.response.detachSocket()).destroy();
      return;
    }
    if (r.uri.path == '/key') {
      r.response.write('{"object":"list","data":[{"id":"qwen-plus"}]}');
      await r.response.close();
      return;
    }
    final client = HttpClient();
    try {
      final out = await client.openUrl(
        r.method,
        _workerOrigin.resolve(r.uri.path),
      );
      r.headers.forEach((name, values) {
        if (name != 'host') out.headers.set(name, values);
      });
      await out.addStream(r);
      final back = await out.close();
      r.response.statusCode = back.statusCode;
      r.response.headers.contentType = back.headers.contentType;
      await r.response.addStream(back);
      await r.response.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<NoteWorkspace> _open(int i) => NoteWorkspace.open(
    localDirectory: Directory('${root.path}/local$i'),
    vaultDirectory: Directory('${root.path}/vault$i'),
    clock: () => now,
    // The same id sequence on each device lets a note captured on the second
    // device stand in for the same note arriving through Obsidian Sync.
    createId: () => 'shared-id-${++_counters[i]}',
    notifications: ports[i],
    connection: WorkspaceConnection(
      secureStore: _stores[i],
      textApiBase: Uri.parse('http://127.0.0.1:${_proxy.port}/'),
      keyCheck: AiKeyCheck(
        endpoint: Uri.parse('http://127.0.0.1:${_proxy.port}/key'),
      ),
      pairingEndpoint: Uri.parse('http://127.0.0.1:${_proxy.port}'),
      allowLocalPairingForTests: true,
    ),
  );

  Future<void> reopen(int i) async {
    await workspaces[i].close();
    workspaces[i] = await _open(i);
  }

  /// The same to-do note with two confirmed actions on device [i].
  Future<WorkspaceNote> todo(int i) async {
    final w = workspaces[i];
    final n = await w.captureText(title: '安排', text: '明天十点买电池，联系物业。');
    return w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: const [
        WorkspaceAction(
          id: 'buy',
          text: '买电池',
          decision: ActionDecision.confirmed,
          reason: 'none',
          timeStatus: ActionTimeStatus.explicit,
          timeExpression: '明天10:00',
        ),
        WorkspaceAction(
          id: 'call',
          text: '联系物业',
          decision: ActionDecision.confirmed,
          reason: 'none',
        ),
      ],
    );
  }

  /// Scheduled system alert for [actionId] on device [i], if any.
  NotificationRequest? alert(int i, String actionId) => ports[i].pending.values
      .where(
        (r) =>
            r.payload['kind'] == 'actionReminder' &&
            r.payload['actionId'] == actionId,
      )
      .firstOrNull;

  Future<void> close() async {
    for (final w in workspaces) {
      await w.close();
    }
    await _proxy.close(force: true);
    _worker.kill(ProcessSignal.sigterm);
    await _worker.exitCode;
    await root.delete(recursive: true);
  }
}
