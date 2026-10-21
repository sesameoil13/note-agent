import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

class BudgetMemoryStore implements SecureCredentialStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async {
    value = v;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

class BudgetFixture {
  late Process worker;
  late Uri endpoint;
  late HttpServer router;
  bool omitCost = false, generationAvailable = false;
  int generationReads = 0;
  final modelStatuses = <int>[];
  bool malformedContent = false;
  bool reuseGenerationId = false;
  Map<String, dynamic>? modelResult;
  double generationCost = 0.00002;
  Future<void> Function()? beforeReply;
  final modelRequests = <Map<String, dynamic>>[];
  final workspaces = <NoteWorkspace>[];
  final stores = <BudgetMemoryStore>[];
  late Directory root;
  Future<void> start() async {
    root = await Directory.systemTemp.createTemp('budget-fixture-');
    worker = await Process.start(
      Platform.environment['NOTE_AGENT_NODE'] ?? 'node',
      ['tools/budget-harness.mjs'],
      workingDirectory: 'services/pairing',
    );
    worker.stderr.transform(utf8.decoder).listen((_) {});
    endpoint = Uri.parse(
      await worker.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15)),
    );
    router = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    router.listen((r) async {
      if (r.uri.path == '/chat/completions') {
        final request = jsonDecode(
          await utf8.decoder.bind(r).join(),
        ) as Map<String, dynamic>;
        modelRequests.add(request);
        final status = modelStatuses.isEmpty ? 200 : modelStatuses.removeAt(0);
        if (status != 200) {
          r.response.statusCode = status;
          r.response.write('{}');
          await r.response.close();
          return;
        }
        final input = jsonDecode(
          (request['messages'] as List).last['content'] as String,
        ) as Map;
        await beforeReply?.call();
        r.response.write(
          jsonEncode({
            'id': reuseGenerationId
                ? 'gen-reused-receipt'
                : 'gen-budget-fixture-${modelRequests.length}',
            'model': 'deepseek/deepseek-v4.1-flash',
            'usage': {
              if (!omitCost) 'cost': 0.00001,
              'prompt_tokens': 37,
              'completion_tokens': 22,
            },
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'content': malformedContent
                      ? '{broken'
                      : jsonEncode(
                          modelResult == null
                              ? {
                                  'sourceId': input['sourceId'],
                                  'kind': 'ordinary',
                                  'title': '记录想法',
                                  'body': '整理后的普通想法。',
                                }
                              : {
                                  'sourceId': input['sourceId'],
                                  ...modelResult!,
                                },
                        ),
                },
              },
            ],
          }),
        );
      } else if (r.uri.path == '/generation') {
        generationReads++;
        if (generationAvailable) {
          r.response.write(
            jsonEncode({
              'data': {
                'id': r.uri.queryParameters['id'],
                'total_cost': generationCost,
              },
            }),
          );
        } else {
          r.response.statusCode = 404;
          r.response.write('{}');
        }
      } else {
        r.response.write('{"data":{"is_management_key":false}}');
      }
      await r.response.close();
    });
    for (var i = 0; i < 3; i++) {
      final store = BudgetMemoryStore();
      stores.add(store);
      final vault = await Directory('${root.path}/vault$i').create();
      workspaces.add(
        await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local$i'),
          vaultDirectory: vault,
          connection: WorkspaceConnection(
            secureStore: store,
            textApiBase: Uri.parse('http://127.0.0.1:${router.port}/'),
            openRouter: OpenRouterKeyCheck(
              endpoint: Uri.parse('http://127.0.0.1:${router.port}/key'),
            ),
            pairingEndpoint: endpoint,
            allowLocalPairingForTests: true,
          ),
        ),
      );
    }
    final owner = workspaces.first.connection;
    await owner.connectOpenRouter('sk-or-v1-budget-fixture-only-key');
    await owner.activatePairing(
      setupToken: 'local-test-setup-only',
      deviceName: 'owner',
    );
    for (final workspace in workspaces.skip(1)) {
      await owner.createPairing();
      await workspace.connection.joinPairing(
        owner.pairing.code!,
        deviceName: 'member',
      );
      await owner.refreshPairing();
      await owner.approvePairing(
        verificationCode: owner.pairing.verificationCode!,
      );
      await workspace.connection.refreshPairing();
      await owner.refreshPairing();
    }
  }

  Future<void> advanceTo(DateTime time) async {
    final client = HttpClient();
    final request = await client.postUrl(endpoint.resolve('/fixture-clock'));
    request.write(time.millisecondsSinceEpoch.toString());
    final response = await request.close();
    await response.drain<void>();
    client.close();
  }

  Future<void> reopen(int i) async {
    await workspaces[i].close();
    workspaces[i] = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local$i'),
      vaultDirectory: Directory('${root.path}/vault$i'),
      connection: WorkspaceConnection(
        secureStore: stores[i],
        textApiBase: Uri.parse('http://127.0.0.1:${router.port}/'),
        openRouter: OpenRouterKeyCheck(
          endpoint: Uri.parse('http://127.0.0.1:${router.port}/key'),
        ),
        pairingEndpoint: endpoint,
        allowLocalPairingForTests: true,
      ),
    );
  }

  Future<void> close() async {
    for (final w in workspaces) {
      await w.close();
    }
    await router.close(force: true);
    worker.kill(ProcessSignal.sigterm);
    await worker.exitCode;
    await root.delete(recursive: true);
  }
}
