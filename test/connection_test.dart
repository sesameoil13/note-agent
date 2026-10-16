import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

class MemorySecureStore implements SecureCredentialStore {
  String? value;
  bool failNextWrite = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw const FileSystemException("OS store locked");
    }
    this.value = value;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

void main() {
  test('a failed pairing creation can be cancelled without removing the checked Key', () async {
    final folder = await Directory.systemTemp.createTemp('pairing-cancel-');
    final vault = await Directory('${folder.path}/vault').create();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/key') {
        if (request.method == 'GET' &&
            request.headers.value('authorization') ==
                'Bearer sk-or-v1-still-valid-test-key') {
          request.response.write('{"data":{"is_management_key":false}}');
        } else {
          request.response.statusCode = 401;
        }
      } else if (request.uri.path == '/v1/enroll') {
        request.response.write('{"role":"owner"}');
      } else {
        request.response.statusCode = 404;
        request.response.write('{"error":"pair_not_found"}');
      }
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${folder.path}/state'),
      vaultDirectory: vault,
      connection: WorkspaceConnection(
        secureStore: MemorySecureStore(),
        openRouter: OpenRouterKeyCheck(endpoint: endpoint.resolve('/key')),
        pairingEndpoint: endpoint,
        allowLocalPairingForTests: true,
      ),
    );
    addTearDown(() async {
      await workspace.close();
      await server.close(force: true);
      await folder.delete(recursive: true);
    });
    await workspace.connection.connectOpenRouter(
      'sk-or-v1-still-valid-test-key',
    );
    await workspace.connection.activatePairing(
      setupToken: 'test-setup',
      deviceName: 'Mac',
    );
    await expectLater(
      workspace.connection.createPairing(),
      throwsA(isA<ConnectionFailure>()),
    );
    await workspace.connection.cancelPairing();
    expect(workspace.connection.pairing.phase, 'ready');
    await workspace.connection.checkOpenRouter();
    expect(workspace.connection.state.connectionVerified, isTrue);
  });

  test('two workspaces pair through the real local Worker with owner approval and retain their own vaults', () async {
    final root = await Directory.systemTemp.createTemp('pairing-');
    final process = await Process.start(
      Platform.environment['NOTE_AGENT_NODE'] ?? 'node',
      ['tools/local-harness.mjs'],
      workingDirectory: 'services/pairing',
    );
    process.stderr.transform(utf8.decoder).listen((_) {});
    final endpoint = Uri.parse(
      await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 20)),
    );
    final ownerStore = MemorySecureStore(), memberStore = MemorySecureStore();
    final proxy = HttpClient();
    var failNextAck = false;
    var tamperNextResult = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/key') {
        if (request.method == 'GET' &&
            request.headers.value('authorization') ==
                'Bearer sk-or-v1-paired-test-key') {
          request.response.write('{"data":{"is_management_key":false}}');
        } else {
          request.response.statusCode = 401;
        }
      } else if (request.uri.path.endsWith('/ack') && failNextAck) {
        failNextAck = false;
        request.response.statusCode = 503;
        request.response.write('{"error":"service_unavailable"}');
      } else {
        final upstream = await proxy.openUrl(
          request.method,
          endpoint.resolve(request.uri.path),
        );
        request.headers.forEach((name, values) {
          if (name == 'authorization' || name == 'content-type') {
            upstream.headers.set(name, values);
          }
        });
        await upstream.addStream(request);
        final result = await upstream.close();
        request.response.statusCode = result.statusCode;
        if (request.uri.path.endsWith('/result') && tamperNextResult) {
          tamperNextResult = false;
          final data = jsonDecode(
            await utf8.decoder.bind(result).join(),
          ) as Map<String, dynamic>;
          final ciphertext = data['ciphertext'] as String;
          data['ciphertext'] =
              (ciphertext.startsWith('A') ? 'B' : 'A') +
              ciphertext.substring(1);
          request.response.write(jsonEncode(data));
        } else {
          await request.response.addStream(result);
        }
      }
      await request.response.close();
    });
    final pairingEndpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final keyCheck = OpenRouterKeyCheck(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/key'),
    );
    final ownVault = await Directory('${root.path}/mac-vault').create();
    final otherVault = await Directory('${root.path}/phone-vault').create();
    final owner = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/mac-state'),
      vaultDirectory: ownVault,
      connection: WorkspaceConnection(
        secureStore: ownerStore,
        openRouter: keyCheck,
        pairingEndpoint: pairingEndpoint,
        allowLocalPairingForTests: true,
      ),
    );
    final phone = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/phone-state'),
      vaultDirectory: otherVault,
      connection: WorkspaceConnection(
        secureStore: memberStore,
        openRouter: keyCheck,
        pairingEndpoint: pairingEndpoint,
        allowLocalPairingForTests: true,
      ),
    );
    addTearDown(() async {
      await owner.close();
      await phone.close();
      await server.close(force: true);
      proxy.close(force: true);
      process.kill();
      await process.exitCode;
      await root.delete(recursive: true);
    });
    await owner.captureText(title: 'Mac 本机笔记', text: '仅保留在原库');
    await phone.captureText(title: '手机本机笔记', text: '目录仍由此设备授权');
    await owner.connection.connectOpenRouter('sk-or-v1-paired-test-key');
    await owner.connection.activatePairing(
      setupToken: 'local-test-setup-only',
      deviceName: 'Mac',
    );
    await owner.connection.createPairing();
    final code = owner.connection.pairing.code!;
    await phone.connection.joinPairing(code, deviceName: '手机');
    expect(phone.connection.state.hasKey, isFalse);
    await owner.connection.refreshPairing();
    expect(
      owner.connection.pairing.verificationCode,
      phone.connection.pairing.verificationCode,
    );
    await owner.connection.approvePairing(
      verificationCode: phone.connection.pairing.verificationCode!,
    );
    tamperNextResult = true;
    await expectLater(
      phone.connection.refreshPairing(),
      throwsA(
        isA<ConnectionFailure>().having(
          (error) => error.message,
          'message',
          contains('校验失败'),
        ),
      ),
    );
    expect(phone.connection.state.hasKey, isFalse);
    memberStore.failNextWrite = true;
    await expectLater(
      phone.connection.refreshPairing(),
      throwsA(isA<ConnectionFailure>()),
    );
    expect(phone.connection.state.hasKey, isFalse);
    await phone.connection.restore();
    failNextAck = true;
    await expectLater(
      phone.connection.refreshPairing(),
      throwsA(isA<ConnectionFailure>()),
    );
    expect(phone.connection.state.hasKey, isTrue);
    await phone.connection.restore();
    await phone.connection.refreshPairing();
    await phone.connection.checkOpenRouter();
    expect(phone.connection.state.connectionVerified, isTrue);
    expect(phone.connection.pairing.role, 'member');
    expect(owner.notes.single.title, 'Mac 本机笔记');
    expect(phone.notes.single.title, '手机本机笔记');
    expect(await File('${ownVault.path}/手机本机笔记.md').exists(), isFalse);
    expect(await File('${otherVault.path}/Mac 本机笔记.md').exists(), isFalse);
  });

  test('a checked OpenRouter connection survives reopening without changing the vault', () async {
    final folder = await Directory.systemTemp.createTemp('connection-');
    final vault = await Directory('${folder.path}/vault').create();
    final store = MemorySecureStore();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'GET' &&
          request.uri.path == '/key' &&
          request.headers.value('authorization') ==
              'Bearer sk-or-v1-test-only-key') {
        request.response.write(
          jsonEncode({
            'data': {'is_management_key': false, 'limit_remaining': 4.2},
          }),
        );
      } else {
        request.response.statusCode = 401;
      }
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}/key');
    final first = await NoteWorkspace.open(
      localDirectory: Directory('${folder.path}/state'),
      vaultDirectory: vault,
      connection: WorkspaceConnection(
        secureStore: store,
        openRouter: OpenRouterKeyCheck(endpoint: endpoint),
      ),
    );
    addTearDown(() async {
      await server.close(force: true);
      await folder.delete(recursive: true);
    });
    await first.connection.connectOpenRouter('sk-or-v1-test-only-key');
    expect(first.connection.state.message, contains('连接成功'));
    await first.captureText(title: '本机记录', text: '连接不代替本机笔记授权');
    await first.close();
    final reopened = await NoteWorkspace.open(
      localDirectory: Directory('${folder.path}/state'),
      vaultDirectory: vault,
      connection: WorkspaceConnection(
        secureStore: store,
        openRouter: OpenRouterKeyCheck(endpoint: endpoint),
      ),
    );
    addTearDown(reopened.close);
    await reopened.connection.restore();
    await reopened.connection.checkOpenRouter();
    expect(reopened.connection.state.hasKey, isTrue);
    expect(reopened.connection.state.connectionVerified, isTrue);
    await expectLater(
      reopened.connection.connectOpenRouter('sk-or-v1-invalid-new-key'),
      throwsA(isA<ConnectionFailure>()),
    );
    expect(
      reopened.connection.state.message,
      isNot(contains('sk-or-v1-invalid-new-key')),
    );
    await reopened.connection.restore();
    await reopened.connection.checkOpenRouter();
    expect(reopened.connection.state.connectionVerified, isTrue);
    expect(reopened.notes.single.text, '连接不代替本机笔记授权');
    expect(reopened.connection.state.message, isNot(contains('笔记已同步')));
  });
}
