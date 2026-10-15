import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:note_agent/workspace_platform.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows restores its local storage and refuses opening a missing note',
    (tester) async {
      final platform = WorkspacePlatform();
      final location = await platform.restoreLocation();
      expect(await location.localDirectory.exists(), isTrue);
      expect(location.localDirectory.isAbsolute, isTrue);

      final outside = await Directory.systemTemp.createTemp(
        'note-agent-outside-vault-',
      );
      addTearDown(() => outside.delete(recursive: true));
      await expectLater(
        platform.openInObsidian('${outside.path}/不存在的记录.md'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'error code',
            'note_path',
          ),
        ),
      );
    },
    skip: !Platform.isWindows,
  );
}
