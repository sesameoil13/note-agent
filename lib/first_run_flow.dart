import 'package:flutter/material.dart';

import 'connection.dart';
import 'first_run.dart';
import 'note_workspace.dart';
import 'secure_connection_field.dart';
import 'setup_screen.dart';
import 'workspace_platform.dart';

/// The connection operations the sequence needs: OpenRouter and pairing.
abstract interface class FirstRunServices {
  WorkspaceConnectionState get state;
  WorkspacePairingState get pairing;
  bool get pairingServiceConfigured;
  Future<void> connectAi(String key);
  Future<void> checkAi();
  Future<void> activatePairing({
    required String setupToken,
    required String deviceName,
  });
  Future<void> joinPairing(String code, {required String deviceName});
  Future<void> refreshPairing();
  Future<void> cancelPairing();
}

class ConnectionFirstRunServices implements FirstRunServices {
  ConnectionFirstRunServices(this.connection);
  final WorkspaceConnection connection;
  @override
  WorkspaceConnectionState get state => connection.state;
  @override
  WorkspacePairingState get pairing => connection.pairing;
  @override
  bool get pairingServiceConfigured => connection.pairingServiceConfigured;
  @override
  Future<void> connectAi(String key) => connection.connectAi(key);
  @override
  Future<void> checkAi() => connection.checkAi();
  @override
  Future<void> activatePairing({
    required String setupToken,
    required String deviceName,
  }) => connection.activatePairing(
    setupToken: setupToken,
    deviceName: deviceName,
  );
  @override
  Future<void> joinPairing(String code, {required String deviceName}) =>
      connection.joinPairing(code, deviceName: deviceName);
  @override
  Future<void> refreshPairing() => connection.refreshPairing();
  @override
  Future<void> cancelPairing() => connection.cancelPairing();
}

/// What the App observes now, read fresh for every modal.
FirstRunFacts firstRunFacts(
  FirstRunServices connection,
  NoteWorkspace? workspace,
) {
  final setup = workspace?.setup;
  return FirstRunFacts(
    hasKey: connection.state.hasKey,
    // Without a pairing service there is no identity to register.
    registered:
        connection.pairing.role != null || !connection.pairingServiceConfigured,
    vaultChosen: workspace != null,
    backupReady: setup?.backupReady ?? false,
    obsidianChecked:
        setup != null && obsidianChecks.every((c) => setup.isReported(c.$1)),
  );
}

/// The four Obsidian checks, worded as in the Settings page.
const obsidianChecks = [
  (SetupCheck.correctVaultOpened, '我已在 Obsidian 打开同一个库并核对笔记'),
  (SetupCheck.standardPlan, '我已核对官方 Sync Standard：1 个远程库、单文件 5 MB、总存储 1 GB'),
  (SetupCheck.otherFileTypes, '我已在 Sync 中启用需要的音频、PDF 与其他文件类型'),
  (SetupCheck.hiddenProperties, '我已在 Obsidian 设置 → 编辑器中将文档属性显示设为隐藏'),
];

/// Shows the first-run sequence as one modal at a time. It closes when the
/// user finishes the done step; every answer is saved as it is given.
Future<void> showFirstRun(
  BuildContext context, {
  required FirstRunServices connection,
  required FirstRunAnswers answers,
  required Future<void> Function(FirstRunAnswers) saveAnswers,
  required NoteWorkspace? Function() workspace,
  required Future<void> Function() chooseVault,
}) {
  final compact = MediaQuery.sizeOf(context).width < 600;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) {
      // Leaving is only through the done step; Back must not skip the vault.
      final flow = PopScope(
        canPop: false,
        child: FirstRunFlow(
          connection: connection,
          answers: answers,
          saveAnswers: saveAnswers,
          workspace: workspace,
          chooseVault: chooseVault,
        ),
      );
      return compact
          ? Dialog.fullscreen(child: flow)
          : Dialog(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: flow,
              ),
            );
    },
  );
}

class FirstRunFlow extends StatefulWidget {
  const FirstRunFlow({
    super.key,
    required this.connection,
    required this.answers,
    required this.saveAnswers,
    required this.workspace,
    required this.chooseVault,
  });
  final FirstRunServices connection;
  final FirstRunAnswers answers;
  final Future<void> Function(FirstRunAnswers) saveAnswers;
  final NoteWorkspace? Function() workspace;
  final Future<void> Function() chooseVault;

  @override
  State<FirstRunFlow> createState() => _FirstRunFlowState();
}

class _FirstRunFlowState extends State<FirstRunFlow> {
  late FirstRunAnswers _answers = widget.answers;
  bool _busy = false;
  String? _error;
  final _key = TextEditingController();
  final _activation = TextEditingController();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _obsidian = <SetupCheck>{};
  final _platform = WorkspacePlatform();
  String? _backupResult;

  /// The backup modal stays up until 继续, so the separate remote-slot
  /// decision can be made there once the backup is ready.
  bool _holdBackup = false;

  /// A step reached with 上一步; shown until the user moves forward from it.
  FirstRunStep? _revisit;
  FirstRunStep _shown = FirstRunStep.welcome;

  /// The service already has an original device, so this one should join.
  bool _alreadyEnrolled = false;

  @override
  void dispose() {
    _key.dispose();
    _activation.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  NoteWorkspace? get _workspace => widget.workspace();

  /// Saved first: an answer that can't be kept doesn't move the flow on.
  Future<void> _answer(FirstRunAnswers next) => _run(() async {
    await widget.saveAnswers(next);
    _answers = next;
  }, advance: true);

  /// Runs one step's action; a failure stays on the same modal with its
  /// message. With [advance], success also leaves a step reached by 上一步.
  Future<void> _run(
    Future<void> Function() action, {
    bool advance = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (advance) _forward();
    } on ConnectionFailure catch (failure) {
      _error = failure.message;
    } catch (_) {
      _error = '这一步未完成，请重试。已保存的设置仍保留。';
    }
    if (mounted) setState(() => _busy = false);
  }

  void _continue() => setState(() {
    _error = null;
    _forward();
  });

  /// Leaves a step reached by 上一步 for the next modal in order, until that
  /// catches up with the first unfinished step.
  void _forward() {
    final from = _revisit;
    if (from == null) return;
    final frontier = nextFirstRunStep(
      _answers,
      firstRunFacts(widget.connection, _workspace),
    );
    final next = followingFirstRunStep(from, _answers);
    _revisit =
        next != null &&
            frontier != null &&
            firstRunStepBefore(next, frontier, _answers)
        ? next
        : null;
  }

  void _back(FirstRunStep target) => setState(() {
    _error = null;
    // A revisited backup keeps its place so 继续 steps on one modal at a time.
    _holdBackup = false;
    _revisit = target;
    if (target == FirstRunStep.obsidian) {
      final setup = _workspace?.setup;
      _obsidian
        ..clear()
        ..addAll([
          for (final (check, _) in obsidianChecks)
            if (setup?.isReported(check) ?? false) check,
        ]);
    }
  });

  Future<void> _skip(FirstRunStep step) {
    if (step == FirstRunStep.backup) _holdBackup = false;
    return _answer(_answers.skip(step));
  }

  @override
  Widget build(BuildContext context) {
    final step = nextFirstRunStep(
      _answers,
      firstRunFacts(widget.connection, _workspace),
    );
    if (step == null) return const SizedBox.shrink();
    if (step == FirstRunStep.backup && _revisit == null) _holdBackup = true;
    final shown = _shown =
        _revisit ?? (_holdBackup ? FirstRunStep.backup : step);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(key: ValueKey(shown), child: _modal(shown)),
      ),
    );
  }

  Widget _modal(FirstRunStep step) => switch (step) {
    FirstRunStep.welcome => _page(
      title: '给想法一个落点。',
      body: '随手收集文字、录音和文档，整理成 Obsidian 笔记，并按时提醒待办。接下来几步完成设置。',
      primary: ('开始', () => _answer(_answers.copyWith(started: true))),
    ),
    FirstRunStep.deviceKind => _page(
      title: '这是你的第一台设备吗？',
      body: '第一台设备连接 AI 服务；其余设备通过配对加入，不必重复输入 Key。',
      primary: ('是，第一台', () => _answer(_answers.copyWith(firstDevice: true))),
      secondary: (
        '不是，已在别的设备用过',
        () => _answer(_answers.copyWith(firstDevice: false)),
      ),
    ),
    FirstRunStep.connectAi => _connectAi(),
    FirstRunStep.joinDevice => _joinDevice(),
    FirstRunStep.vault => _vaultStep(),
    FirstRunStep.oldVault => _page(
      title: '你有旧的 Obsidian 笔记库吗？',
      body: '有旧库时，切换前先核对完整备份。App 不会自动寻找、修改或删除旧库。',
      primary: ('没有', () => _answer(_answers.copyWith(hasOldVault: false))),
      secondary: ('有', () => _answer(_answers.copyWith(hasOldVault: true))),
      skip: step,
    ),
    FirstRunStep.backup => _backupStep(),
    FirstRunStep.obsidian => _obsidianStep(),
    FirstRunStep.notifications => _page(
      title: '允许提醒通知',
      body: '待办到时间时由系统通知提醒你。麦克风权限会在第一次录音时再请求。',
      primary: (
        '允许通知',
        () => _run(() async {
          await _workspace!.requestNotificationPermission();
          await _answer(_answers.copyWith(notificationsAsked: true));
        }),
      ),
      skip: step,
    ),
    FirstRunStep.done => _done(),
  };

  Widget _vaultStep() {
    Future<void> choose() => _run(() async {
      await widget.chooseVault();
      if (_workspace == null) {
        throw const ConnectionFailure('未选择笔记库。请选择新的 Obsidian 笔记库文件夹后继续。');
      }
    }, advance: true);
    final current = _workspace;
    if (current != null) {
      return _page(
        title: '选择笔记库',
        body:
            '当前笔记库：${current.vaultStorage.displayName}\n可以继续，或换一个新的 Obsidian 笔记库文件夹（不要选旧库）。',
        primary: ('继续', _continue),
        secondary: ('换一个文件夹', choose),
      );
    }
    return _page(
      title: '选择笔记库',
      body: '请选择新的 Obsidian 笔记库文件夹，不要选旧库。笔记和来源文件都保存在这里。',
      primary: ('选择文件夹', choose),
    );
  }

  Widget _connectAi() {
    final hasKey = widget.connection.state.hasKey;
    final facts = firstRunFacts(widget.connection, _workspace);
    // A received key that failed its check is not a finished connection.
    if (facts.hasKey && facts.registered && !_answers.keyCheckFailed) {
      return _page(
        title: '连接 AI',
        body: 'AI 已连接，本机已登记为原设备。',
        primary: ('继续', _continue),
      );
    }
    return _page(
      title: '连接 AI',
      body:
          '${hasKey ? 'Key 已保存。再输入首次启用码，登记这台设备为原设备。' : '粘贴阿里云百炼（北京地域）的 API Key，并输入首次启用码。Key 在百炼控制台 → API-KEY 创建；检测不调用收费模型。'}'
          '\n首次启用码是部署配对服务时生成的一次性码，只用于登记第一台设备；其余设备通过配对加入，不需要它。'
          '${_alreadyEnrolled ? '\n这个配对服务已经有第一台设备。若这台不是第一台，请改为配对加入。' : ''}',
      fields: [
        if (!hasKey)
          SecureConnectionField(
            controller: _key,
            enabled: !_busy,
            label: '百炼 API Key',
          ),
        SecureConnectionField(
          controller: _activation,
          enabled: !_busy,
          label: '首次启用码',
        ),
        TextField(
          controller: _name,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: '设备名称'),
        ),
      ],
      primary: (
        '检测并启用',
        () => _run(() async {
          // A saved key is not entered again when only registration failed.
          if (!widget.connection.state.hasKey) {
            await widget.connection.connectAi(_key.text);
            _key.clear();
          }
          try {
            await widget.connection.activatePairing(
              setupToken: _activation.text,
              deviceName: _name.text,
            );
          } on ConnectionFailure catch (failure) {
            _alreadyEnrolled = failure.code == 'already_enrolled';
            rethrow;
          }
          _activation.clear();
        }, advance: true),
      ),
      secondary: _alreadyEnrolled
          ? ('改为配对加入', () => _answer(_answers.copyWith(firstDevice: false)))
          : null,
      skip: FirstRunStep.connectAi,
    );
  }

  /// 稍后 here leaves a pending request in place; it never cancels it, and
  /// this device never becomes a second original device.
  /// The outcome is saved, so a restart after a failed check comes back here.
  Future<void> _checkReceivedKey() async {
    try {
      await widget.connection.checkAi();
    } catch (_) {
      await widget.saveAnswers(
        _answers = _answers.copyWith(keyCheckFailed: true),
      );
      rethrow;
    }
    if (_answers.keyCheckFailed) {
      await widget.saveAnswers(
        _answers = _answers.copyWith(keyCheckFailed: false),
      );
    }
  }

  Widget _joinDevice() {
    final pairing = widget.connection.pairing;
    if (pairing.role != null && !_answers.keyCheckFailed) {
      return _page(
        title: '加入已有设备',
        body: '本机已配对，AI 设置已通过连接检测。',
        primary: ('继续', _continue),
      );
    }
    if (_answers.keyCheckFailed && pairing.role != null) {
      return _page(
        title: '加入已有设备',
        body: '配对已完成，但收到的 AI 设置未通过连接检测。请在第一台设备确认 Key 仍然有效，然后重新检测。',
        primary: ('重新检测连接', () => _run(_checkReceivedKey, advance: true)),
        skip: FirstRunStep.joinDevice,
      );
    }
    if (pairing.phase == 'waiting') {
      return _page(
        title: '加入已有设备',
        body:
            '验证码：${pairing.verificationCode ?? '—'}\n两台设备上的验证码必须一致。请在第一台设备核对并批准，然后回到这里刷新。',
        primary: (
          '已批准，刷新',
          () => _run(() async {
            await widget.connection.refreshPairing();
            // Pairing hands over the key unchecked; check it before moving on.
            if (widget.connection.pairing.role != null) {
              await _checkReceivedKey();
              _forward();
            }
          }),
        ),
        // An expired or rejected request can't be refreshed: start over.
        secondary: ('取消，重新输入配对码', () => _run(widget.connection.cancelPairing)),
        skip: FirstRunStep.joinDevice,
      );
    }
    return _page(
      title: '加入已有设备',
      body: '在第一台设备的“连接与设备”中生成一次性配对码（五分钟内有效），输入到这里。AI 设置会随配对安全传来。',
      fields: [
        SecureConnectionField(controller: _code, enabled: !_busy, label: '配对码'),
        TextField(
          controller: _name,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: '设备名称'),
        ),
      ],
      primary: (
        '请求加入',
        () => _run(() async {
          await widget.connection.joinPairing(
            _code.text,
            deviceName: _name.text,
          );
          _code.clear();
        }),
      ),
      skip: FirstRunStep.joinDevice,
    );
  }

  /// Moves on only when the backup is ready: compared (or reported) and the
  /// local import copy kept. The remote-slot switch stays a separate choice.
  Widget _backupStep() {
    final workspace = _workspace!;
    final setup = workspace.setup;
    Widget check(SetupCheck c, String text) => CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: setup.isReported(c),
      onChanged: _busy
          ? null
          : (value) => _run(() => workspace.reportSetupCheck(c, value!)),
      title: Text(text),
    );
    return _page(
      title: '先备份旧库',
      body: '把整个旧库（含附件和隐藏的 .obsidian 文件夹）复制到与同步库分开的位置。App 只读取两边的文件清单与大小，不复制、移动或删除任何文件。',
      fields: [
        if (_platform.supportsFolderComparison)
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    _backupResult = await compareOldVaultBackup(
                      workspace,
                      _platform,
                    );
                  }),
            child: const Text('选择旧库与备份，只读核对'),
          ),
        if (_backupResult != null) Text(_backupResult!),
        if (setup.backupVerifiedAt == null)
          check(SetupCheck.backupComplete, '我已制作并检查独立的完整旧库备份'),
        check(SetupCheck.localImportCopyRetained, '旧库的本地导入副本已保留，不会随远程名额切换删除'),
      ],
      primary: (
        '继续',
        setup.backupReady
            ? () => setState(() {
                _holdBackup = false;
                _forward();
              })
            : null,
      ),
      secondary: setup.backupReady
          ? (
              '单独确认远程名额切换',
              () => _run(() async {
                if (await confirmRemoteSlotSwitch(context, workspace)) {
                  await workspace.confirmRemoteSlotSwitch();
                }
              }),
            )
          : null,
      skip: FirstRunStep.backup,
    );
  }

  Widget _obsidianStep() => _page(
    title: '在 Obsidian 打开同一个文件夹',
    body: '在 Obsidian 库管理中选择“打开文件夹为仓库”，选这里的同一个文件夹，然后核对以下各项。App 无法替你验证，只记录你的确认。',
    fields: [
      for (final (check, text) in obsidianChecks)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _obsidian.contains(check),
          onChanged: _busy
              ? null
              : (value) => setState(
                  () => value! ? _obsidian.add(check) : _obsidian.remove(check),
                ),
          title: Text(text),
        ),
    ],
    primary: (
      '确认',
      _obsidian.length < obsidianChecks.length
          ? null
          : () => _run(() async {
              for (final (check, _) in obsidianChecks) {
                await _workspace!.reportSetupCheck(check, true);
              }
            }, advance: true),
    ),
    skip: FirstRunStep.obsidian,
  );

  Widget _done() {
    final skipped = outstandingFirstRunSteps(
      _answers,
      firstRunFacts(widget.connection, _workspace),
    );
    return _page(
      title: '设置完成',
      body: skipped.isEmpty
          ? 'AI、设备、笔记库与 Obsidian 都已就绪。'
          : '还有 ${skipped.length} 步稍后完成：${skipped.map(firstRunStepLabel).join('、')}。主界面会提示你继续。',
      primary: (
        '开始收集',
        () async {
          await _answer(_answers.finish());
          if (mounted && _answers.finished) Navigator.of(context).pop();
        },
      ),
    );
  }

  Widget _page({
    required String title,
    required String body,
    List<Widget> fields = const [],
    required (String, VoidCallback?) primary,
    (String, VoidCallback)? secondary,
    FirstRunStep? skip,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 16),
      Text(body, style: const TextStyle(height: 1.6)),
      for (final field in fields) ...[const SizedBox(height: 12), field],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : primary.$2,
        child: Text(primary.$1),
      ),
      if (secondary != null)
        OutlinedButton(
          onPressed: _busy ? null : secondary.$2,
          child: Text(secondary.$1),
        ),
      if (skip != null)
        TextButton(
          onPressed: _busy ? null : () => _skip(skip),
          child: const Text('稍后'),
        ),
      if (previousFirstRunStep(_shown, _answers) case final previous?)
        TextButton.icon(
          onPressed: _busy ? null : () => _back(previous),
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('上一步'),
        ),
    ],
  );
}

String firstRunStepLabel(FirstRunStep step) => switch (step) {
  FirstRunStep.connectAi => '连接 AI',
  FirstRunStep.joinDevice => '配对加入',
  FirstRunStep.vault => '选择笔记库',
  FirstRunStep.oldVault => '旧库问题',
  FirstRunStep.backup => '旧库备份',
  FirstRunStep.obsidian => 'Obsidian 核对',
  FirstRunStep.notifications => '提醒通知',
  _ => step.name,
};
