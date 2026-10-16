import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'App key entry survives a new connection through the real OS secure store',
    (tester) async {
      // This guard prevents a test from touching the user's ordinary credential slot.
      expect(const String.fromEnvironment('DEVICE_SLOT'), 't12-native-probe');
      final store = PlatformSecureCredentialStore();
      final folder = await Directory.systemTemp.createTemp('native-t12-');
      final vault = await Directory('${folder.path}/vault').create();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.method == 'GET' &&
            request.uri.path == '/key' &&
            request.headers.value('authorization') ==
                'Bearer sk-or-v1-native-fixture-key') {
          request.response.write('{"data":{"is_management_key":false}}');
        } else {
          request.response.statusCode = 401;
        }
        await request.response.close();
      });
      final metadata = OpenRouterKeyCheck(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/key'),
      );
      await store.delete();
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${folder.path}/state'),
        vaultDirectory: vault,
        connection: WorkspaceConnection(
          secureStore: store,
          openRouter: metadata,
        ),
      );
      try {
        await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
        await tester.tap(find.byTooltip('连接与设备'));
        await tester.pumpAndSettle();
        final keyField = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'OpenRouter API Key',
        );
        await tester.enterText(keyField, 'sk-or-v1-native-fixture-key');
        await tester.tap(find.text('检测并安全保存'));
        await tester.pumpAndSettle();
        expect(workspace.connection.state.connectionVerified, isTrue);
        final restored = WorkspaceConnection(
          secureStore: store,
          openRouter: metadata,
        );
        await restored.restore();
        await restored.checkOpenRouter();
        expect(restored.state.connectionVerified, isTrue);
        expect(find.text('sk-or-v1-native-fixture-key'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await workspace.close();
        await store.delete();
        await server.close(force: true);
        await folder.delete(recursive: true);
      }
    },
  );
}
