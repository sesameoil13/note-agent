import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/first_run.dart';
import 'package:note_agent/first_run_flow.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart' show BudgetMemoryStore;
import 'support/pending_notification_fixture.dart';

/// Stands in for OpenRouter and the pairing service; the flow only sees the
/// connection's public operations and state.
class FakeConnection implements FirstRunServices {
  @override
  bool get pairingServiceConfigured => true;
  bool hasKey = false, approved = false, keyRevoked = false, expired = false;
  String? role, verification;
  String phase = 'setup';
  final calls = <String>[];

  @override
  WorkspaceConnectionState get state => WorkspaceConnectionState(
    hasKey: hasKey,
    connectionVerified: hasKey,
    message: hasKey ? 'OpenRouter 连接成功。' : '尚未连接 OpenRouter。',
  );

  @override
  WorkspacePairingState get pairing => WorkspacePairingState(
    role: role,
    phase: phase,
    verificationCode: verification,
    message: '',
  );

  @override
  Future<void> connectOpenRouter(String enteredKey) async {
    calls.add('key');
    if (enteredKey == 'bad') {
      throw const ConnectionFailure('请输入完整的 OpenRouter API Key。');
    }
    hasKey = true;
  }

  @override
  Future<void> checkOpenRouter() async {
    calls.add('check');
    if (keyRevoked) throw const ConnectionFailure('OpenRouter Key 无效或已撤销。');
  }

  @override
  Future<void> activatePairing({
    required String setupToken,
    required String deviceName,
  }) async {
    calls.add('activate:$deviceName');
    if (setupToken == 'wrong') {
      throw const ConnectionFailure('首次启用码无效，请核对后重试。');
    }
    if (setupToken == 'enrolled') {
      throw const ConnectionFailure(
        '首次启用已完成，请通过原设备配对。',
        code: 'already_enrolled',
      );
    }
    role = 'owner';
    phase = 'ready';
  }

  @override
  Future<void> cancelPairing() async {
    calls.add('cancel');
    phase = 'setup';
    verification = null;
    expired = false;
  }

  @override
  Future<void> joinPairing(String code, {required String deviceName}) async {
    calls.add('join:$deviceName');
    phase = 'waiting';
    verification = '482913';
  }

  @override
  Future<void> refreshPairing() async {
    calls.add('refresh');
    if (expired) throw const ConnectionFailure('配对码已过期，请在原设备重新生成。');
    if (approved) {
      role = 'member';
      phase = 'ready';
      hasKey = true;
    }
  }
}

void main() {
  late Directory root;
  late FakeConnection connection;
  late NoteWorkspace workspace;
  late PendingNotifications port;
  NoteWorkspace? current;
  late List<FirstRunAnswers> saved;
  var failSaves = 0;
  var pickerCancels = false;
  final picks = <String?>[];
  const channel = MethodChannel('dev.noteagent/workspace');

  setUp(() {
    current = null;
    saved = [];
    failSaves = 0;
    pickerCancels = false;
  });

  Future<void> pumpFlow(
    WidgetTester tester, {
    FirstRunAnswers answers = const FirstRunAnswers(),
    bool connected = false,
    bool vaultChosen = false,
    List<SetupCheck> reports = const [],
  }) async {
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('first-run-');
      for (final dir in ['old', 'backup']) {
        await File('${root.path}/$dir/日记.md').create(recursive: true);
        await File('${root.path}/$dir/日记.md').writeAsString('旧库原文');
      }
      connection = FakeConnection();
      if (connected) {
        connection
          ..hasKey = true
          ..role = 'owner'
          ..phase = 'ready';
      }
      port = PendingNotifications();
      workspace = await NoteWorkspace.open(
        localDirectory: Directory('${root.path}/local'),
        vaultDirectory: await Directory('${root.path}/vault').create(),
        connection: WorkspaceConnection(secureStore: BudgetMemoryStore()),
        notifications: port,
      );
      for (final check in reports) {
        await workspace.reportSetupCheck(check, true);
      }
    });
    if (vaultChosen) current = workspace;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'chooseFolder') return picks.removeAt(0);
      throw PlatformException(code: 'unexpected');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    addTearDown(() async {
      await tester.runAsync(() async {
        await workspace.close();
        await root.delete(recursive: true);
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showFirstRun(
                  context,
                  connection: connection,
                  answers: answers,
                  saveAnswers: (next) async {
                    if (failSaves > 0) {
                      failSaves--;
                      throw const ConnectionFailure('系统安全存储暂时不可用，请解锁设备后重试。');
                    }
                    saved.add(next);
                  },
                  workspace: () => current,
                  chooseVault: () async {
                    if (!pickerCancels) current = workspace;
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> tapAndSettle(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.runAsync(() async {
      await tester.tap(target);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the first device goes from welcome to done one modal at a time',
    (tester) async {
      await pumpFlow(tester);
      expect(find.text('给想法一个落点。'), findsOneWidget);
      // One modal at a time: the setup list is nowhere on screen.
      expect(find.text('设置进度'), findsNothing);
      await tapAndSettle(tester, find.text('开始'));

      expect(find.text('这是你的第一台设备吗？'), findsOneWidget);
      await tapAndSettle(tester, find.text('是，第一台'));

      expect(find.text('连接 AI'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'OpenRouter API Key'),
        'sk-or-v1-test-key-0000',
      );
      await tester.enterText(find.widgetWithText(TextField, '首次启用码'), 'setup');
      await tester.enterText(find.widgetWithText(TextField, '设备名称'), 'MacBook');
      await tapAndSettle(tester, find.text('检测并启用'));
      expect(connection.calls, ['key', 'activate:MacBook']);

      expect(find.text('选择笔记库'), findsOneWidget);
      expect(find.textContaining('不要选旧库'), findsOneWidget);
      expect(find.text('稍后'), findsNothing);
      await tapAndSettle(tester, find.text('选择文件夹'));

      expect(find.text('你有旧的 Obsidian 笔记库吗？'), findsOneWidget);
      await tapAndSettle(tester, find.text('没有'));

      expect(find.text('在 Obsidian 打开同一个文件夹'), findsOneWidget);
      for (final box in find.byType(Checkbox).evaluate().toList()) {
        await tapAndSettle(tester, find.byWidget(box.widget));
      }
      await tapAndSettle(tester, find.text('确认'));
      expect(workspace.setup.isReported(SetupCheck.hiddenProperties), isTrue);

      expect(find.text('允许提醒通知'), findsOneWidget);
      await tapAndSettle(tester, find.text('允许通知'));
      expect(port.permissionRequests, 1);

      expect(find.text('设置完成'), findsOneWidget);
      await tapAndSettle(tester, find.text('开始收集'));
      expect(find.text('设置完成'), findsNothing);
      expect(saved.last.finished, isTrue);
      expect(saved.last.firstDevice, isTrue);
      expect(saved.last.hasOldVault, isFalse);
    },
  );

  testWidgets(
    'another device joins by pairing and checks the key it received',
    (tester) async {
      await pumpFlow(
        tester,
        answers: const FirstRunAnswers(started: true, firstDevice: false),
      );
      expect(find.text('加入已有设备'), findsOneWidget);
      expect(find.text('OpenRouter API Key'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, '配对码'),
        'noteagent-pair://join',
      );
      await tester.enterText(find.widgetWithText(TextField, '设备名称'), 'Xiaomi');
      await tapAndSettle(tester, find.text('请求加入'));
      expect(find.textContaining('482913'), findsOneWidget);
      expect(find.textContaining('两台设备上的验证码必须一致'), findsOneWidget);

      // Not approved yet: refreshing stays on the same modal.
      await tapAndSettle(tester, find.text('已批准，刷新'));
      expect(find.text('加入已有设备'), findsOneWidget);

      connection.approved = true;
      await tapAndSettle(tester, find.text('已批准，刷新'));
      expect(connection.calls, ['join:Xiaomi', 'refresh', 'refresh', 'check']);
      expect(find.text('选择笔记库'), findsOneWidget);
    },
  );

  testWidgets(
    'a failed registration keeps the saved key and retries registration only',
    (tester) async {
      await pumpFlow(
        tester,
        answers: const FirstRunAnswers(started: true, firstDevice: true),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'OpenRouter API Key'),
        'sk-or-v1-test-key-0000',
      );
      await tester.enterText(find.widgetWithText(TextField, '首次启用码'), 'wrong');
      await tester.enterText(find.widgetWithText(TextField, '设备名称'), 'MacBook');
      await tapAndSettle(tester, find.text('检测并启用'));
      expect(find.text('首次启用码无效，请核对后重试。'), findsOneWidget);
      expect(find.text('连接 AI'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'OpenRouter API Key'),
        findsNothing,
      );

      await tester.enterText(find.widgetWithText(TextField, '首次启用码'), 'setup');
      await tapAndSettle(tester, find.text('检测并启用'));
      expect(connection.calls, ['key', 'activate:MacBook', 'activate:MacBook']);
      expect(find.text('选择笔记库'), findsOneWidget);
    },
  );

  testWidgets('with an old vault, the backup is compared before moving on', (
    tester,
  ) async {
    await pumpFlow(
      tester,
      answers: const FirstRunAnswers(
        started: true,
        firstDevice: true,
        hasOldVault: true,
      ),
      connected: true,
      vaultChosen: true,
    );
    expect(find.text('先备份旧库'), findsOneWidget);
    picks.addAll(['${root.path}/old', '${root.path}/backup']);
    await tapAndSettle(tester, find.text('选择旧库与备份，只读核对'));
    expect(find.textContaining('App 已核对：旧库 1 个文件'), findsOneWidget);
    // A complete comparison alone is not enough: the local copy must be kept.
    expect(find.text('先备份旧库'), findsOneWidget);
    await tapAndSettle(tester, find.text('旧库的本地导入副本已保留，不会随远程名额切换删除'));
    await tapAndSettle(tester, find.text('继续'));
    expect(find.text('在 Obsidian 打开同一个文件夹'), findsOneWidget);
    expect(workspace.setup.backupReady, isTrue);
  });

  testWidgets(
    '稍后 everywhere still ends at done, which lists what was put off',
    (tester) async {
      await pumpFlow(
        tester,
        answers: const FirstRunAnswers(started: true, firstDevice: true),
      );
      await tapAndSettle(tester, find.text('稍后'));
      await tapAndSettle(tester, find.text('选择文件夹'));
      await tapAndSettle(tester, find.text('稍后'));
      await tapAndSettle(tester, find.text('稍后'));
      await tapAndSettle(tester, find.text('稍后'));
      expect(find.text('设置完成'), findsOneWidget);
      expect(
        find.textContaining('还有 4 步稍后完成：连接 AI、旧库问题、Obsidian 核对、提醒通知'),
        findsOneWidget,
      );
      await tapAndSettle(tester, find.text('开始收集'));
      expect(saved.last.finished, isTrue);
      expect(saved.last.skipped, hasLength(4));
    },
  );

  testWidgets('an answer that cannot be saved does not move the flow on', (
    tester,
  ) async {
    await pumpFlow(tester);
    failSaves = 1;
    await tapAndSettle(tester, find.text('开始'));
    expect(find.text('系统安全存储暂时不可用，请解锁设备后重试。'), findsOneWidget);
    expect(find.text('给想法一个落点。'), findsOneWidget);
    await tapAndSettle(tester, find.text('开始'));
    expect(find.text('这是你的第一台设备吗？'), findsOneWidget);
  });

  testWidgets(
    'a paired device whose received key fails its check stays to retry',
    (tester) async {
      await pumpFlow(
        tester,
        answers: const FirstRunAnswers(started: true, firstDevice: false),
      );
      await tester.enterText(
        find.widgetWithText(TextField, '配对码'),
        'noteagent-pair://join',
      );
      await tester.enterText(find.widgetWithText(TextField, '设备名称'), 'Xiaomi');
      await tapAndSettle(tester, find.text('请求加入'));
      connection
        ..approved = true
        ..keyRevoked = true;
      await tapAndSettle(tester, find.text('已批准，刷新'));
      expect(find.text('OpenRouter Key 无效或已撤销。'), findsOneWidget);
      expect(find.text('选择笔记库'), findsNothing);
      connection.keyRevoked = false;
      await tapAndSettle(tester, find.text('重新检测连接'));
      expect(find.text('选择笔记库'), findsOneWidget);
    },
  );

  testWidgets(
    'system Back and a cancelled picker leave the vault step in place',
    (tester) async {
      await pumpFlow(
        tester,
        answers: const FirstRunAnswers(started: true, firstDevice: true),
        connected: true,
      );
      expect(find.text('选择笔记库'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('选择笔记库'), findsOneWidget);
      pickerCancels = true;
      await tapAndSettle(tester, find.text('选择文件夹'));
      expect(find.text('选择笔记库'), findsOneWidget);
      expect(find.textContaining('未选择笔记库'), findsOneWidget);
    },
  );

  testWidgets(
    'an expired pairing request can be cancelled and a new code entered',
    (tester) async {
      await pumpFlow(
        tester,
        answers: const FirstRunAnswers(started: true, firstDevice: false),
      );
      await tester.enterText(
        find.widgetWithText(TextField, '配对码'),
        'noteagent-pair://join',
      );
      await tester.enterText(find.widgetWithText(TextField, '设备名称'), 'Xiaomi');
      await tapAndSettle(tester, find.text('请求加入'));
      connection.expired = true;
      await tapAndSettle(tester, find.text('已批准，刷新'));
      expect(find.text('配对码已过期，请在原设备重新生成。'), findsOneWidget);
      await tapAndSettle(tester, find.text('取消，重新输入配对码'));
      expect(connection.calls.last, 'cancel');
      expect(find.widgetWithText(TextField, '配对码'), findsOneWidget);
    },
  );

  testWidgets('a failed key check is saved so a restart comes back to it', (
    tester,
  ) async {
    await pumpFlow(
      tester,
      answers: const FirstRunAnswers(started: true, firstDevice: false),
    );
    await tester.enterText(
      find.widgetWithText(TextField, '配对码'),
      'noteagent-pair://join',
    );
    await tester.enterText(find.widgetWithText(TextField, '设备名称'), 'Xiaomi');
    await tapAndSettle(tester, find.text('请求加入'));
    connection
      ..approved = true
      ..keyRevoked = true;
    await tapAndSettle(tester, find.text('已批准，刷新'));
    expect(saved.last.keyCheckFailed, isTrue);
    connection.keyRevoked = false;
    await tapAndSettle(tester, find.text('重新检测连接'));
    expect(saved.last.keyCheckFailed, isFalse);
  });

  testWidgets(
    'the activation code is explained, and a refused one offers pairing instead',
    (tester) async {
      await pumpFlow(
        tester,
        answers: const FirstRunAnswers(started: true, firstDevice: true),
      );
      expect(find.textContaining('首次启用码是部署配对服务时生成的一次性码'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'OpenRouter API Key'),
        'sk-or-v1-test-key-0000',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '首次启用码'),
        'enrolled',
      );
      await tester.enterText(find.widgetWithText(TextField, '设备名称'), 'MacBook');
      await tapAndSettle(tester, find.text('检测并启用'));
      expect(find.textContaining('已经有第一台设备'), findsOneWidget);
      await tapAndSettle(tester, find.text('改为配对加入'));
      expect(find.text('加入已有设备'), findsOneWidget);
      expect(saved.last.firstDevice, isFalse);
    },
  );

  testWidgets('上一步 returns to the previous modal and lets an answer change', (
    tester,
  ) async {
    await pumpFlow(tester);
    expect(find.text('上一步'), findsNothing);
    await tapAndSettle(tester, find.text('开始'));
    await tapAndSettle(tester, find.text('是，第一台'));
    expect(find.text('连接 AI'), findsOneWidget);

    await tapAndSettle(tester, find.text('上一步'));
    expect(find.text('这是你的第一台设备吗？'), findsOneWidget);
    await tapAndSettle(tester, find.text('不是，已在别的设备用过'));
    expect(find.text('加入已有设备'), findsOneWidget);
    expect(saved.last.firstDevice, isFalse);

    await tapAndSettle(tester, find.text('上一步'));
    await tapAndSettle(tester, find.text('上一步'));
    expect(find.text('给想法一个落点。'), findsOneWidget);
    await tapAndSettle(tester, find.text('开始'));
    expect(find.text('这是你的第一台设备吗？'), findsOneWidget);
  });

  testWidgets('上一步 to a finished step shows it again with 继续', (tester) async {
    await pumpFlow(
      tester,
      answers: const FirstRunAnswers(started: true, firstDevice: true),
      connected: true,
      vaultChosen: true,
    );
    expect(find.text('你有旧的 Obsidian 笔记库吗？'), findsOneWidget);
    await tapAndSettle(tester, find.text('上一步'));
    expect(find.text('选择笔记库'), findsOneWidget);
    expect(find.textContaining('当前笔记库：vault'), findsOneWidget);
    await tapAndSettle(tester, find.text('继续'));
    expect(find.text('你有旧的 Obsidian 笔记库吗？'), findsOneWidget);

    await tapAndSettle(tester, find.text('上一步'));
    await tapAndSettle(tester, find.text('上一步'));
    expect(find.text('连接 AI'), findsOneWidget);
    expect(find.textContaining('本机已登记为原设备'), findsOneWidget);
    // Forward again goes one modal at a time back to where the user was.
    await tapAndSettle(tester, find.text('继续'));
    expect(find.textContaining('当前笔记库：vault'), findsOneWidget);
    await tapAndSettle(tester, find.text('继续'));
    expect(find.text('你有旧的 Obsidian 笔记库吗？'), findsOneWidget);
  });

  testWidgets('a failed key check is not shown as a finished connection', (
    tester,
  ) async {
    await pumpFlow(
      tester,
      answers: const FirstRunAnswers(
        started: true,
        firstDevice: true,
        keyCheckFailed: true,
      ),
      connected: true,
      vaultChosen: true,
    );
    expect(find.text('连接 AI'), findsOneWidget);
    expect(find.textContaining('本机已登记为原设备'), findsNothing);
    expect(find.text('稍后'), findsOneWidget);
  });

  testWidgets('上一步 through a finished backup keeps going one modal at a time', (
    tester,
  ) async {
    await pumpFlow(
      tester,
      answers: const FirstRunAnswers(
        started: true,
        firstDevice: true,
        hasOldVault: true,
      ),
      connected: true,
      vaultChosen: true,
      reports: const [
        SetupCheck.backupComplete,
        SetupCheck.localImportCopyRetained,
        SetupCheck.correctVaultOpened,
        SetupCheck.standardPlan,
        SetupCheck.otherFileTypes,
        SetupCheck.hiddenProperties,
      ],
    );
    expect(find.text('允许提醒通知'), findsOneWidget);
    await tapAndSettle(tester, find.text('上一步'));
    await tapAndSettle(tester, find.text('上一步'));
    expect(find.text('先备份旧库'), findsOneWidget);
    await tapAndSettle(tester, find.text('继续'));
    expect(find.text('在 Obsidian 打开同一个文件夹'), findsOneWidget);
  });
}
