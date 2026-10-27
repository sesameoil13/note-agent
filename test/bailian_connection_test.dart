import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart' show BudgetMemoryStore;

/// A stand-in for Bailian's OpenAI-compatible endpoint on this Mac. Listing
/// models is the free key check (issue #34, Q2).
Future<HttpServer> fakeBailian({required String acceptedKey}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final authorized =
        request.headers.value('authorization') == 'Bearer $acceptedKey';
    if (request.method == 'GET' &&
        request.uri.path == '/compatible-mode/v1/models') {
      if (authorized) {
        request.response.write(
          jsonEncode({
            'object': 'list',
            'data': [
              {'id': 'qwen-plus', 'object': 'model'},
            ],
          }),
        );
      } else {
        request.response.statusCode = 401;
        request.response.write(
          '{"error":{"code":"invalid_api_key","message":"Incorrect API key provided."}}',
        );
      }
    } else {
      request.response.statusCode = 404;
    }
    await request.response.close();
  });
  return server;
}

WorkspaceConnection connectionFor(HttpServer server, BudgetMemoryStore store) {
  final base = Uri.parse('http://127.0.0.1:${server.port}/compatible-mode/v1/');
  return WorkspaceConnection(
    secureStore: store,
    keyCheck: AiKeyCheck(endpoint: base.resolve('models')),
    textApiBase: base,
    allowLocalPairingForTests: true,
  );
}

void main() {
  test(
    'a Bailian key is checked for free and kept for the next launch',
    () async {
      final server = await fakeBailian(
        acceptedKey: 'sk-bailian-valid-test-key-0000',
      );
      addTearDown(() => server.close(force: true));
      final store = BudgetMemoryStore();
      final connection = connectionFor(server, store);

      await connection.connectAi('sk-bailian-valid-test-key-0000');
      expect(connection.state.hasKey, isTrue);
      expect(connection.state.connectionVerified, isTrue);
      final saved = jsonDecode(store.value!) as Map;
      expect(saved['aiKey'], 'sk-bailian-valid-test-key-0000');
      expect(saved['aiProvider'], 'bailian-cn');
      expect(saved.containsKey('openRouterKey'), isFalse);

      final relaunched = connectionFor(server, store);
      await relaunched.restore();
      expect(relaunched.state.hasKey, isTrue);
      await relaunched.checkAi();
      expect(relaunched.state.connectionVerified, isTrue);
    },
  );

  test('a refused key is reported and not saved', () async {
    final server = await fakeBailian(
      acceptedKey: 'sk-bailian-valid-test-key-0000',
    );
    addTearDown(() => server.close(force: true));
    final store = BudgetMemoryStore();
    final connection = connectionFor(server, store);

    await expectLater(
      connection.connectAi('sk-bailian-revoked-test-key-00'),
      throwsA(
        isA<ConnectionFailure>().having(
          (f) => f.message,
          'message',
          contains('Key 无效或已被撤销'),
        ),
      ),
    );
    expect(connection.state.hasKey, isFalse);
    expect(store.value, isNull);
  });

  test('a device that only has an old OpenRouter key is asked to reconnect, and keeps it', () async {
    final server = await fakeBailian(
      acceptedKey: 'sk-bailian-valid-test-key-0000',
    );
    addTearDown(() => server.close(force: true));
    final store = BudgetMemoryStore()
      ..value = jsonEncode({
        'openRouterKey': 'sk-or-v1-old-key-from-before-the-switch',
        'device': {'id': 'mac-1', 'role': 'owner', 'name': 'Mac'},
      });
    final connection = connectionFor(server, store);
    await connection.restore();

    expect(connection.state.hasKey, isFalse);
    expect(connection.state.message, contains('阿里云百炼'));
    // Device identity is untouched; the old key stays only on this device.
    expect(connection.pairing.role, 'owner');
    await connection.connectAi('sk-bailian-valid-test-key-0000');
    final saved = jsonDecode(store.value!) as Map;
    expect(saved['openRouterKey'], 'sk-or-v1-old-key-from-before-the-switch');
    expect(saved['aiKey'], 'sk-bailian-valid-test-key-0000');
    expect((saved['device'] as Map)['id'], 'mac-1');
  });

  test(
    'only the fixed HTTPS Bailian endpoint is accepted outside local tests',
    () {
      expect(
        () => WorkspaceConnection(
          secureStore: BudgetMemoryStore(),
          textApiBase: Uri.parse('https://example.com/compatible-mode/v1/'),
        ),
        throwsArgumentError,
      );
      expect(
        WorkspaceConnection(secureStore: BudgetMemoryStore()).textApiBase,
        Uri.parse('https://dashscope.aliyuncs.com/compatible-mode/v1/'),
      );
    },
  );

  group('pairing hands the Bailian key over, and refuses an old format', () {
    late Process worker;
    late Uri pairingEndpoint;
    late HttpServer bailian;
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bailian-pairing-');
      worker = await Process.start(
        Platform.environment['NOTE_AGENT_NODE'] ?? 'node',
        ['tools/local-harness.mjs'],
        workingDirectory: 'services/pairing',
      );
      worker.stderr.transform(utf8.decoder).listen((_) {});
      pairingEndpoint = Uri.parse(
        await worker.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 20)),
      );
      bailian = await fakeBailian(
        acceptedKey: 'sk-bailian-owner-test-key-0000',
      );
    });
    tearDown(() async {
      await bailian.close(force: true);
      worker.kill();
      await worker.exitCode;
      await root.delete(recursive: true);
    });

    Future<NoteWorkspace> device(
      String name,
      BudgetMemoryStore store, {
      int configVersion = 2,
    }) async {
      final base = Uri.parse(
        'http://127.0.0.1:${bailian.port}/compatible-mode/v1/',
      );
      return NoteWorkspace.open(
        localDirectory: Directory('${root.path}/$name-state'),
        vaultDirectory: await Directory('${root.path}/$name-vault').create(),
        connection: WorkspaceConnection(
          secureStore: store,
          keyCheck: AiKeyCheck(endpoint: base.resolve('models')),
          textApiBase: base,
          pairingEndpoint: pairingEndpoint,
          allowLocalPairingForTests: true,
          pairingConfigVersionForTests: configVersion,
        ),
      );
    }

    Future<void> pairUpToApproval(
      NoteWorkspace owner,
      NoteWorkspace phone,
    ) async {
      await owner.connection.connectAi('sk-bailian-owner-test-key-0000');
      await owner.connection.activatePairing(
        setupToken: 'local-test-setup-only',
        deviceName: 'Mac',
      );
      await owner.connection.createPairing();
      await phone.connection.joinPairing(
        owner.connection.pairing.code!,
        deviceName: '手机',
      );
      await owner.connection.refreshPairing();
      await owner.connection.approvePairing(
        verificationCode: phone.connection.pairing.verificationCode!,
      );
    }

    test(
      'the paired device receives the Bailian key, tagged with its provider',
      () async {
        final phoneStore = BudgetMemoryStore();
        final owner = await device('mac', BudgetMemoryStore());
        final phone = await device('phone', phoneStore);
        addTearDown(() async {
          await owner.close();
          await phone.close();
        });
        await pairUpToApproval(owner, phone);
        await phone.connection.refreshPairing();
        expect(phone.connection.pairing.role, 'member');
        final saved = jsonDecode(phoneStore.value!) as Map;
        expect(saved['aiKey'], 'sk-bailian-owner-test-key-0000');
        expect(saved['aiProvider'], 'bailian-cn');
        await phone.connection.checkAi();
        expect(phone.connection.state.connectionVerified, isTrue);
      },
    );

    test('an original device on the old version is refused before anything is saved', () async {
      final phoneStore = BudgetMemoryStore();
      final owner = await device('mac', BudgetMemoryStore(), configVersion: 1);
      final phone = await device('phone', phoneStore);
      addTearDown(() async {
        await owner.close();
        await phone.close();
      });
      await pairUpToApproval(owner, phone);
      await expectLater(
        phone.connection.refreshPairing(),
        throwsA(
          isA<ConnectionFailure>().having(
            (f) => f.message,
            'message',
            contains('请先更新原设备'),
          ),
        ),
      );
      expect(phone.connection.state.hasKey, isFalse);
      final saved = jsonDecode(phoneStore.value!) as Map;
      expect(saved.containsKey('aiKey'), isFalse);
      expect(saved.containsKey('openRouterKey'), isFalse);
      expect(phone.connection.pairing.role, isNull);
    });
  });
}
