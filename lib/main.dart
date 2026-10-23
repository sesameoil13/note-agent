import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'note_workspace.dart';
import 'connection.dart';
import 'connection_screen.dart';
import 'attachment_sources.dart';
import 'sync_panel.dart';
import 'accessible_icon_button.dart';
import 'method_channel_audio.dart';
import 'recording_panel.dart';
import 'workspace_platform.dart';
import 'document_panel.dart';
import 'setup_screen.dart';
import 'budget_panel.dart';
import 'action_confirmation_screen.dart';
import 'reminder_screen.dart';
import 'notification_platform.dart';

void main() => runApp(const NoteAgentApp());

const graphite = Color(0xFF101215);
const slate = Color(0xFF1C2024);
const bone = Color(0xFFEDE7DB);
const ash = Color(0xFF767C82);
const acid = Color(0xFFCDFF3A);
const oxide = Color(0xFFFF4A18);

class NoteAgentApp extends StatelessWidget {
  const NoteAgentApp({super.key, this.initialWorkspace});

  final NoteWorkspace? initialWorkspace;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '笔记工作区',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: graphite,
      colorScheme: const ColorScheme.dark(
        primary: acid,
        onPrimary: graphite,
        surface: slate,
        onSurface: bone,
        error: oxide,
        onError: graphite,
      ),
      textTheme: ThemeData.dark().textTheme.apply(
        bodyColor: bone,
        displayColor: bone,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: graphite,
        labelStyle: TextStyle(color: ash),
        hintStyle: TextStyle(color: ash),
        contentPadding: EdgeInsets.all(16),
        border: OutlineInputBorder(borderRadius: BorderRadius.zero),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: ash),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: acid, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const RoundedRectangleBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: bone,
          side: const BorderSide(color: ash),
          shape: const RoundedRectangleBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
      dividerColor: ash,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: acid,
        selectionColor: Color(0x554C5E18),
      ),
      dialogTheme: const DialogThemeData(shape: RoundedRectangleBorder()),
    ),
    home: _WorkspaceScreen(initialWorkspace: initialWorkspace),
  );
}

class _WorkspaceScreen extends StatefulWidget {
  const _WorkspaceScreen({this.initialWorkspace});
  final NoteWorkspace? initialWorkspace;

  @override
  State<_WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<_WorkspaceScreen>
    with WidgetsBindingObserver {
  final _platform = WorkspacePlatform();
  late final WorkspaceConnection _connection;
  final _title = TextEditingController();
  final _text = TextEditingController();
  final _search = TextEditingController();
  final _editTitle = TextEditingController();
  String? _editingNoteId;
  NoteWorkspace? _workspace;
  String? _selectedId;
  String? _error;
  String? _deviceInfo;
  String? _pendingCaptureId;
  String? _pendingTitle;
  String? _pendingText;
  bool _loading = false;
  bool _saving = false;
  bool _composing = true;
  bool _recordingPage = false;
  StreamSubscription<void>? _notificationInteractions;
  bool _pendingListOpen = false;

  void _watchNotificationInteractions() {
    unawaited(_notificationInteractions?.cancel());
    _notificationInteractions = _workspace?.notificationInteractionSignals
        .listen((_) {
          unawaited(_takeNotificationNavigation());
        });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_takeNotificationNavigation());
    });
  }

  Future<void> _takeNotificationNavigation() async {
    final workspace = _workspace;
    if (workspace == null) return;
    // Both reads start together; completion and snooze from an alert apply
    // even when the App was closed when the user responded.
    final pending = workspace.takePendingConfirmationNavigation();
    final reminders = workspace.takeReminderInteractions();
    try {
      final noteId = await reminders;
      if (mounted && workspace == _workspace) {
        setState(() {
          if (noteId != null && !_saving) {
            _selectedId = noteId;
            _composing = false;
            _recordingPage = false;
          }
        });
      }
    } catch (_) {
      /* Unapplied responses stay with the system adapter until next resume. */
    }
    try {
      final open = await pending;
      if (mounted && workspace == _workspace && open) await _openPendingList();
    } catch (_) {
      /* An unread response remains available on next resume. */
    }
  }

  Future<void> _openPendingList() async {
    if (_pendingListOpen || _workspace == null) return;
    _pendingListOpen = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PendingActionsScreen(workspace: _workspace!),
        ),
      );
    } finally {
      _pendingListOpen = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _workspace = widget.initialWorkspace;
    _connection = _workspace?.connection ?? WorkspaceConnection.platform();
    if (_workspace == null) _restore();
    _watchNotificationInteractions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_notificationInteractions?.cancel());
    _title.dispose();
    _text.dispose();
    _search.dispose();
    _editTitle.dispose();
    // The injected workspace belongs to its caller (including behavioral tests).
    if (_workspace != widget.initialWorkspace) _workspace?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumeAudioQueue();
      unawaited(_takeNotificationNavigation());
      final workspace = _workspace;
      if (workspace != null) {
        // Returning from Obsidian: read its edits, then reconcile reminders.
        unawaited(
          workspace
              .readVaultEdits()
              .then((_) {
                if (mounted) setState(() {});
              })
              .catchError((Object e) {
                if (mounted) setState(() => _error = _errorMessage(e));
              }),
        );
      }
    }
  }

  void _resumeAudioQueue() {
    final workspace = _workspace;
    if (workspace == null) return;
    unawaited(
      workspace.resumePendingAudioProcessing().catchError((Object error) {
        if (mounted) setState(() => _error = _errorMessage(error));
      }),
    );
  }

  Future<void> _restore() async {
    setState(() => _loading = true);
    try {
      final location = await _platform.restoreLocation();
      _deviceInfo = location.deviceInfo;
      _error = location.authorizationError;
      if (location.hasVault) await _open(location);
    } catch (error) {
      _error = _errorMessage(error);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _chooseVault() async {
    if (_workspace?.recording.isActive ?? false) {
      setState(() => _error = '请先结束并保存当前录音，再切换笔记库。');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final location = await _platform.chooseLocation();
      if (location != null) {
        await _open(location);
      } else {
        _error = '未更改笔记库，输入已保留。';
      }
    } catch (error) {
      _error = _errorMessage(error);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _showSetup() async {
    final action = await Navigator.of(context).push<SetupAction>(
      MaterialPageRoute(
        builder: (_) =>
            SetupScreen(workspace: _workspace, connection: _connection),
      ),
    );
    if (!mounted) return;
    if (action == SetupAction.chooseVault) await _chooseVault();
    if (action == SetupAction.record) setState(() => _recordingPage = true);
  }

  Future<void> _open(WorkspaceLocation location) async {
    final workspace = await NoteWorkspace.open(
      localDirectory: location.localDirectory,
      vaultDirectory: location.vaultDirectory,
      vaultStorage: location.vaultStorage,
      connection: _connection,
      notifications: Platform.isMacOS ? MethodChannelNotifications() : null,
      audioPlatform:
          (Platform.isMacOS && location.vaultDirectory != null) ||
              Platform.isAndroid
          ? MethodChannelAudioPlatform()
          : null,
    );
    if (!mounted) {
      await workspace.close();
      return;
    }
    final old = _workspace;
    if (old?.vaultStorage.identity != workspace.vaultStorage.identity) {
      _pendingCaptureId = null;
    }
    _workspace = workspace;
    _watchNotificationInteractions();
    _deviceInfo = location.deviceInfo;
    _error = location.authorizationError;
    _selectedId = null;
    _editingNoteId = null;
    _search.clear();
    _composing = true;
    _recordingPage = workspace.recordingAvailable;
    if (old != widget.initialWorkspace) await old?.close();
    _resumeAudioQueue();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final pending =
          _pendingCaptureId != null &&
          _pendingTitle == _title.text &&
          _pendingText == _text.text &&
          _workspace!.notes.any((note) => note.id == _pendingCaptureId);
      final note = pending
          ? await _workspace!.retryNoteExport(_pendingCaptureId!)
          : await _workspace!.captureText(title: _title.text, text: _text.text);
      if (!mounted) return;
      setState(() {
        _selectedId = note.id;
        if (note.status == NoteStatus.localSaved) {
          _composing = false;
          _pendingCaptureId = null;
          _title.clear();
          _text.clear();
        } else {
          _pendingCaptureId = note.id;
          _pendingTitle = _title.text;
          _pendingText = _text.text;
          _error = note.error ?? '原文已保留，笔记库尚未写入。请重新授权后重试。';
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _retry(WorkspaceNote note) async {
    setState(() => _saving = true);
    try {
      await _workspace!.retryNoteExport(note.id);
    } catch (error) {
      _error = _errorMessage(error);
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _openInObsidian(WorkspaceNote note) async {
    try {
      await _platform.openInObsidian(note.notePath);
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    }
  }

  Future<void> _rename(WorkspaceNote note) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final renamed = await _workspace!.renameNote(
        note.id,
        title: _editTitle.text,
      );
      if (mounted) setState(() => _editTitle.text = renamed.title);
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openSource(WorkspaceNote note) async {
    try {
      await _platform.openInObsidian(note.sourcePath);
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    }
  }

  void _documentChanged(String? id) {
    if (!mounted) return;
    setState(() {
      if (id != null) {
        _selectedId = id;
        _composing = false;
        _recordingPage = false;
      }
    });
  }

  String _errorMessage(Object error) {
    if (error is PlatformException) return error.message ?? '系统操作未完成，请重试。';
    if (error is ArgumentError) return error.message.toString();
    return '操作未完成，输入已保留。$error';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 960;
          return Column(
            children: [
              _header(wide),
              if (_workspace != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.rule),
                    label: Text(
                      '待确认 ${_workspace!.pendingConfirmationNotes.length}',
                    ),
                    onPressed: _saving ? null : _openPendingList,
                  ),
                ),
              if (_workspace != null && constraints.maxWidth < 720)
                _mobileNavigation(),
              if (_deviceInfo != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    _deviceInfo!,
                    style: const TextStyle(color: ash, fontSize: 12),
                  ),
                ),
              if (_error != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: oxide, width: 2)),
                  ),
                  child: Text(_error!, style: const TextStyle(color: bone)),
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _workspace == null
                    ? _setup()
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (wide) _sidebar(),
                          if (!_recordingPage && constraints.maxWidth >= 720)
                            SizedBox(width: 280, child: _noteList()),
                          Expanded(
                            child: _recordingPage
                                ? RecordingPanel(
                                    key: ValueKey(_workspace),
                                    workspace: _workspace!,
                                    onStateChanged: () {
                                      if (mounted) setState(() {});
                                    },
                                  )
                                : _composing
                                ? _composer()
                                : _detail(),
                          ),
                        ],
                      ),
              ),
              _footer(),
            ],
          );
        },
      ),
    ),
  );

  Future<void> _openBudget() async {
    final workspace = _workspace;
    if (workspace == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => BudgetPanel(workspace: workspace)),
    );
    if (mounted) setState(() => _editingNoteId = null);
  }

  Future<void> _openConnection() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ConnectionScreen(connection: _connection),
    ),
  );

  Widget _header(bool wide) => Container(
    padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 16, vertical: 16),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: ash)),
    ),
    child: Row(
      children: [
        Container(
          width: 24,
          height: 24,
          color: acid,
          child: const Icon(Icons.notes, size: 16, color: graphite),
        ),
        SizedBox(width: wide ? 16 : 8),
        if (wide || MediaQuery.sizeOf(context).width >= 410)
          Text(
            wide ? 'RIGID BODY' : 'RIGID',
            style: TextStyle(
              fontSize: wide ? 20 : 18,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
            ),
          ),
        if (wide) ...[
          const SizedBox(width: 24),
          const Text('笔记工作区', style: TextStyle(color: ash)),
        ],
        const Spacer(),
        if (_workspace != null && wide)
          AccessibleIconButton(
            onPressed: _saving ? null : _openBudget,
            label: 'AI 与共享预算',
            icon: const Icon(Icons.account_balance_wallet_outlined),
          ),
        if (_workspace != null)
          AccessibleIconButton(
            onPressed: _saving || _loading
                ? null
                : () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ReminderScreen(workspace: _workspace!),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
            label: '提醒与默认时间',
            icon: const Icon(Icons.notifications_outlined),
          ),
        if (wide) ...[
          AccessibleIconButton(
            onPressed: _saving || _loading ? null : _showSetup,
            label: '设置与首次引导',
            icon: const Icon(Icons.tune),
          ),
          AccessibleIconButton(
            onPressed: _saving ? null : _openConnection,
            label: '连接与设备',
            icon: const Icon(Icons.link),
          ),
        ] else
          PopupMenuButton<String>(
            tooltip: '更多操作',
            enabled: !_saving && !_loading,
            onSelected: (action) async {
              switch (action) {
                case 'budget':
                  await _openBudget();
                case 'setup':
                  await _showSetup();
                case 'connection':
                  await _openConnection();
              }
            },
            itemBuilder: (_) => [
              if (_workspace != null)
                const PopupMenuItem(value: 'budget', child: Text('AI 与共享预算')),
              const PopupMenuItem(value: 'setup', child: Text('设置与首次引导')),
              const PopupMenuItem(value: 'connection', child: Text('连接与设备')),
            ],
          ),
        if (_workspace != null) ...[
          if (wide) ...[
            DocumentImportButton(
              workspace: _workspace!,
              onChanged: _documentChanged,
            ),
            const SizedBox(width: 8),
            DocumentImportButton(
              workspace: _workspace!,
              onChanged: _documentChanged,
              word: true,
            ),
            const SizedBox(width: 8),
          ],
          if (_workspace!.recordingAvailable ||
              _platform.supportsSourceFiles) ...[
            if (wide)
              OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () => setState(() => _recordingPage = true),
                icon: const Icon(Icons.mic, size: 16),
                label: const Text('录音'),
              )
            else if (MediaQuery.sizeOf(context).width >= 720)
              AccessibleIconButton(
                onPressed: _saving
                    ? null
                    : () => setState(() => _recordingPage = true),
                label: '录音',
                icon: const Icon(Icons.mic),
              ),
            const SizedBox(width: 8),
          ],
          if (!wide && MediaQuery.sizeOf(context).width >= 720)
            AccessibleIconButton(
              onPressed: _showRecent,
              label: '最近记录',
              icon: const Icon(Icons.notes),
            ),
          if (!wide && MediaQuery.sizeOf(context).width >= 720)
            AccessibleIconButton(
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      _composing = true;
                      _recordingPage = false;
                      _selectedId = null;
                      _error = null;
                    }),
              label: '新建文字',
              icon: const Icon(Icons.add),
            ),
          if (wide)
            OutlinedButton(
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      _composing = true;
                      _recordingPage = false;
                      _selectedId = null;
                      _error = null;
                    }),
              child: const Text('新建文字'),
            ),
        ],
      ],
    ),
  );

  Widget _mobileNavigation() => Container(
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: ash)),
    ),
    child: Wrap(
      spacing: 16,
      children: [
        TextButton(
          onPressed: _saving
              ? null
              : () => setState(() {
                  _composing = true;
                  _recordingPage = false;
                  _selectedId = null;
                  _error = null;
                }),
          child: const Text('新建文字'),
        ),
        Tooltip(
          message: '录音',
          child: TextButton(
            onPressed: _saving
                ? null
                : () => setState(() => _recordingPage = true),
            child: const Text('录音'),
          ),
        ),
        Tooltip(
          message: '最近记录',
          child: TextButton(
            onPressed: _saving ? null : _showRecent,
            child: const Text('历史记录'),
          ),
        ),
      ],
    ),
  );

  Widget _sidebar() => Container(
    width: 192,
    decoration: const BoxDecoration(
      border: Border(right: BorderSide(color: ash)),
    ),
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 24),
          child: Text(
            'WORKSPACE / 01',
            style: TextStyle(fontSize: 12, color: ash, fontFamily: 'monospace'),
          ),
        ),
        _navItem(
          '收集文字',
          Icons.add,
          _composing && !_recordingPage,
          () => setState(() {
            _composing = true;
            _recordingPage = false;
          }),
        ),
        const SizedBox(height: 8),
        _navItem(
          '最近记录',
          Icons.notes,
          !_composing && !_recordingPage,
          _showRecent,
        ),
        if (_workspace!.recordingAvailable ||
            _platform.supportsSourceFiles) ...[
          const SizedBox(height: 8),
          _navItem(
            '收集录音',
            Icons.mic,
            _recordingPage,
            () => setState(() => _recordingPage = true),
          ),
        ],
        const Spacer(),
        const Text('当前笔记库', style: TextStyle(color: ash, fontSize: 12)),
        const SizedBox(height: 8),
        Text(
          _workspace!.vaultStorage.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _saving ? null : _chooseVault,
          child: const Text('选择笔记库'),
        ),
      ],
    ),
  );

  Widget _navItem(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) => Material(
    color: selected ? acid : slate,
    child: InkWell(
      onTap: _saving ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 16, color: selected ? graphite : bone),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected ? graphite : bone,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  void _showRecent() {
    final notes = _workspace?.notes ?? [];
    if (MediaQuery.sizeOf(context).width < 720) {
      final workspace = _workspace!;
      final originalCount =
          workspace.recordings.length +
          workspace.audioSources
              .where(
                (source) => !workspace.recordings.any(
                  (recording) => recording.id == source.id,
                ),
              )
              .length;
      Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => DefaultTabController(
            length: 2,
            initialIndex: notes.isEmpty && originalCount > 0 ? 1 : 0,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('历史记录'),
                bottom: TabBar(
                  tabs: [
                    Tab(text: '笔记 ${notes.length}'),
                    Tab(text: '原始录音 $originalCount'),
                  ],
                ),
              ),
              body: TabBarView(
                children: [
                  StatefulBuilder(
                    builder: (_, refresh) =>
                        _noteList(refresh: () => refresh(() {})),
                  ),
                  RecordingPanel(workspace: workspace, historyOnly: true),
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      setState(() {
        _composing = false;
        _recordingPage = false;
        if (notes.isNotEmpty) _selectedId ??= notes.first.id;
      });
    }
  }

  Widget _noteList({VoidCallback? refresh}) {
    final notes = _workspace!.search(_search.text);
    return Container(
      decoration: const BoxDecoration(
        color: slate,
        border: Border(right: BorderSide(color: ash)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Text(
                  _search.text.trim().isEmpty ? '最近记录' : '搜索结果',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  notes.length.toString().padLeft(2, '0'),
                  style: const TextStyle(color: ash, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                labelText: '搜索笔记',
                hintText: '标题或原文关键词',
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                          refresh?.call();
                        },
                      ),
              ),
              onChanged: (_) {
                setState(() {});
                refresh?.call();
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: notes.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _search.text.trim().isEmpty
                          ? '还没有记录。\n收集的文字会出现在这里。'
                          : '没有匹配的记录。',
                      style: TextStyle(color: ash, height: 1.7),
                    ),
                  )
                : ListView.builder(
                    itemCount: notes.length,
                    itemBuilder: (context, index) {
                      final note = notes[index];
                      final selected =
                          !_recordingPage &&
                          !_composing &&
                          note.id == _selectedId;
                      return Container(
                        margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        decoration: BoxDecoration(
                          color: graphite,
                          border: Border.all(
                            color: selected ? acid : ash,
                            width: selected ? 2 : 1,
                          ),
                        ),
                        child: InkWell(
                          onTap: _saving
                              ? null
                              : () {
                                  setState(() {
                                    _selectedId = note.id;
                                    _composing = false;
                                    _recordingPage = false;
                                    _error = null;
                                  });
                                  if (MediaQuery.sizeOf(this.context).width <
                                      720) {
                                    Navigator.pop(context);
                                  }
                                },
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: note.titleCollision
                                      ? const EdgeInsets.all(8)
                                      : EdgeInsets.zero,
                                  decoration: BoxDecoration(
                                    border: note.titleCollision
                                        ? Border.all(color: bone, width: 2)
                                        : null,
                                  ),
                                  child: Text(
                                    note.title,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  note.text.replaceAll('\n', ' '),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: ash,
                                    height: 1.6,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  note.status == NoteStatus.localSaved
                                      ? '本机已保存'
                                      : '原文已保留 · 待写入',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: ash,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _composer() => SingleChildScrollView(
    padding: const EdgeInsets.all(32),
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '收集文字',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              '先留在本机，再成为自己的笔记。',
              style: TextStyle(color: ash, height: 1.5),
            ),
            const SizedBox(height: 32),
            if (MediaQuery.sizeOf(context).width < 960) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    DocumentImportButton(
                      workspace: _workspace!,
                      onChanged: _documentChanged,
                    ),
                    DocumentImportButton(
                      workspace: _workspace!,
                      onChanged: _documentChanged,
                      word: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
            TextField(
              controller: _title,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: '标题',
                hintText: '用一句简短的话概括内容',
              ),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _text,
              enabled: !_saving,
              minLines: 10,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: '正文',
                hintText: '输入或粘贴想保留的文字……',
                alignLabelWithHint: true,
              ),
              style: const TextStyle(fontSize: 16, height: 1.5),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '保留完整原文 · 保存为普通笔记',
                    style: TextStyle(color: ash, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '正在保存…' : '保存文字'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _actionOperation(Future<void> Function() operation) async {
    try {
      await operation();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : _errorMessage(e));
      }
    }
  }

  Future<DateTime?> _pickReopenTime() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
      helpText: '重新开启后的提醒日期',
    );
    if (day == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
      helpText: '重新开启后的提醒时间',
    );
    if (time == null) return null;
    return DateTime(day.year, day.month, day.day, time.hour, time.minute);
  }

  Widget _actionControls(WorkspaceNote note, WorkspaceAction action) {
    if (!action.actionConfirmed) return const SizedBox.shrink();
    final state = _workspace!.actionState(note.id, action.id);
    final hasReminder = _workspace!.reminders.any(
      (r) => r.noteId == note.id && r.actionId == action.id,
    );
    final snooze = _workspace!.reminderDefaults.snoozeMinutes;
    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!state.completed) ...[
          TextButton(
            onPressed: _saving
                ? null
                : () => _actionOperation(
                    () => _workspace!.completeAction(note.id, action.id),
                  ),
            child: const Text('完成'),
          ),
          if (hasReminder)
            PopupMenuButton<int>(
              enabled: !_saving,
              tooltip: '选择稍后提醒时长',
              onSelected: (minutes) => _actionOperation(
                () => _workspace!.snoozeReminder(
                  note.id,
                  action.id,
                  minutes: minutes,
                ),
              ),
              itemBuilder: (_) => [
                for (final m in {snooze, 10, 60, 120, 1440})
                  PopupMenuItem(
                    value: m,
                    child: Text(
                      '${m == 1440 ? '明天此时' : '$m 分钟后'}${m == snooze ? '（默认）' : ''}',
                    ),
                  ),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text('稍后提醒…'),
              ),
            ),
        ] else
          TextButton(
            onPressed: _saving
                ? null
                : () async {
                    final time = await _pickReopenTime();
                    if (time == null) return;
                    await _actionOperation(
                      () => _workspace!.reopenAction(note.id, action.id, time),
                    );
                  },
            child: const Text('重新开启'),
          ),
        if (state.notePending)
          TextButton(
            onPressed: _saving
                ? null
                : () => _actionOperation(
                    () => _workspace!.retryActionCompletionSave(note.id),
                  ),
            child: const Text('重试写入勾选'),
          ),
      ],
    );
  }

  String _actionReminderLabel(WorkspaceNote note, WorkspaceAction action) {
    final state = action.actionConfirmed
        ? _workspace!.actionState(note.id, action.id)
        : null;
    if (state != null && state.completed) {
      return ['已完成，提醒已取消', if (state.notePending) '笔记中的勾选尚未写入'].join(' · ');
    }
    final reminder = _workspace!.reminders
        .where((r) => r.noteId == note.id && r.actionId == action.id)
        .firstOrNull;
    if (reminder == null) return '尚未排程提醒';
    return [
      reminderStatusLabel(reminder.status),
      reminderTimeLabel(reminder.time),
      if (reminder.snoozed) '已稍后提醒',
      if (reminder.timeNeedsConfirmation) '时间待确认，当前使用默认提醒',
      if (state != null && state.notePending) '笔记中的勾选尚未写入',
    ].join(' · ');
  }

  Widget _detail() {
    final notes = _workspace!.notes;
    if (notes.isEmpty) return _composer();
    final note = notes.firstWhere(
      (item) => item.id == _selectedId,
      orElse: () => notes.first,
    );
    if (_editingNoteId != note.id) {
      _editingNoteId = note.id;
      _editTitle.text = note.title;
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                note.kind == NoteKind.todo ? '待办笔记' : '普通笔记',
                style: const TextStyle(color: ash, fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _editTitle,
                enabled: !_saving && note.status == NoteStatus.localSaved,
                decoration: InputDecoration(
                  labelText: '标题',
                  enabledBorder: note.titleCollision
                      ? const OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: bone, width: 2),
                        )
                      : null,
                  focusedBorder: const OutlineInputBorder(
                    borderRadius: BorderRadius.zero,
                    borderSide: BorderSide(color: acid, width: 2),
                  ),
                ),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
                onSubmitted: (_) {
                  if (!_saving) _rename(note);
                },
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _saving || note.status != NoteStatus.localSaved
                      ? null
                      : () => _rename(note),
                  child: const Text('保存标题'),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.status == NoteStatus.localSaved
                          ? '本机已保存'
                          : note.status == NoteStatus.renamePending ||
                                note.status == NoteStatus.renameFailed
                          ? '原笔记已保留，标题与链接更新待重试'
                          : '原文已保留，笔记库写入失败',
                      style: TextStyle(
                        color: note.status == NoteStatus.localSaved
                            ? ash
                            : oxide,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (note.status == NoteStatus.localSaved)
                    OutlinedButton(
                      onPressed: () => _openInObsidian(note),
                      child: const Text('在 Obsidian 打开'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              NoteSyncSummary(note: note),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _saving || note.status != NoteStatus.localSaved
                      ? null
                      : () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ActionConfirmationScreen(
                                workspace: _workspace!,
                                noteId: note.id,
                              ),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                  child: const Text('修正类型与行动'),
                ),
              ),
              if (note.status != NoteStatus.localSaved) ...[
                const SizedBox(height: 16),
                Text(
                  note.error ?? '正在写入笔记库。',
                  style: const TextStyle(color: ash),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => _retry(note),
                    child: const Text('重试写入'),
                  ),
                ),
              ],
              const SizedBox(height: 32),
              if (note.kind == NoteKind.todo) ...[
                _sectionTitle('待办'),
                for (final a in note.actions)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${a.actionConfirmed && _workspace!.actionState(note.id, a.id).completed ? '■' : '□'} ${a.text}',
                          style: const TextStyle(fontSize: 16),
                        ),
                        Text(
                          '${a.actionConfirmed ? '行动已确认' : '待确认 · ${actionReasonLabel(a.reason)}'} · ${actionTimeLabel(a)}',
                          style: const TextStyle(color: ash),
                        ),
                        Text(
                          _actionReminderLabel(note, a),
                          style: const TextStyle(color: ash, fontSize: 12),
                        ),
                        _actionControls(note, a),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
              ],
              _sectionTitle(note.kind == NoteKind.todo ? '摘要' : '正文'),
              const SizedBox(height: 16),
              SelectableText(
                note.text.trimRight(),
                style: const TextStyle(fontSize: 16, height: 1.5),
              ),
              const SizedBox(height: 32),
              _sectionTitle('关联'),
              const SizedBox(height: 16),
              if (note.associations.isEmpty)
                const Text('暂无关联', style: TextStyle(color: ash)),
              for (final association in note.associations)
                ExpansionTile(
                  title: Text(association.title),
                  subtitle: const Text('查看关联理由'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(association.reason),
                    ),
                    TextButton(
                      onPressed: _saving || note.associationSavePending
                          ? null
                          : () async {
                              try {
                                await _workspace!.removeAssociation(
                                  note.id,
                                  association.targetNoteId,
                                );
                                if (mounted) setState(() {});
                              } catch (e) {
                                if (mounted) {
                                  setState(() {
                                    _error = _errorMessage(e);
                                  });
                                }
                              }
                            },
                      child: const Text('移除关联'),
                    ),
                  ],
                ),
              if (note.associationSavePending)
                OutlinedButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          try {
                            await _workspace!.retryAssociationSave(note.id);
                            if (mounted) setState(() {});
                          } catch (e) {
                            if (mounted) {
                              setState(() {
                                _error = _errorMessage(e);
                              });
                            }
                          }
                        },
                  child: const Text('重试保存关联'),
                ),
              const SizedBox(height: 32),
              _sectionTitle('来源'),
              const SizedBox(height: 16),
              if (note.document != null) ...[
                DocumentStatusView(
                  key: ValueKey(note.id),
                  workspace: _workspace!,
                  note: note,
                  onChanged: () => _documentChanged(null),
                ),
                const SizedBox(height: 16),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _showOriginal(note),
                  icon: const Icon(Icons.description_outlined, size: 16),
                  label: Text(note.document == null ? '原始文字' : '提取结果'),
                ),
              ),
              AttachmentSources(
                workspace: _workspace!,
                noteId: note.id,
                onChanged: () {
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 16),
              Text(
                '记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(note.modifiedAt)}',
                style: const TextStyle(
                  color: ash,
                  fontSize: 12,
                  height: 1.7,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) => Row(
    children: [
      Container(width: 8, height: 16, color: ash),
      const SizedBox(width: 8),
      Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ],
  );

  void _showOriginal(WorkspaceNote note) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        note.document == null
            ? '收集的原文'
            : note.document?.result?.engine.startsWith('pdfium/') == true
            ? 'PDF 提取结果'
            : 'Word 提取结果',
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: SelectableText(
            note.originalText,
            style: const TextStyle(fontSize: 16, height: 1.5),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _openSource(note),
          child: const Text('打开来源文件'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Widget _setup() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '给想法一个落点。',
              style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 24),
            const Text(
              '选择自己的本地笔记库，开始收集。\n在设置与首次引导中连接服务、配对并核对 Obsidian。',
              style: TextStyle(fontSize: 16, height: 1.7, color: ash),
            ),
            const SizedBox(height: 32),
            FilledButton(onPressed: _showSetup, child: const Text('开始设置')),
            TextButton(onPressed: _chooseVault, child: const Text('先选择本地笔记库')),
          ],
        ),
      ),
    ),
  );

  Widget _footer() => Container(
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: ash)),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    child: Row(
      children: [
        const Icon(Icons.circle, size: 8, color: ash),
        const SizedBox(width: 8),
        const Text('本机存储', style: TextStyle(fontSize: 12, color: ash)),
        const Spacer(),
        if (_workspace != null)
          TextButton(
            onPressed: () => showSyncStorage(context, _workspace!, _platform),
            child: const Text('同步与存储'),
          ),
        if (_workspace != null && MediaQuery.sizeOf(context).width < 960)
          TextButton(
            onPressed: _saving || _loading ? null : _chooseVault,
            child: const Text('选择笔记库'),
          ),
        if (MediaQuery.sizeOf(context).width >= 600)
          Text(
            _recordingPage ? 'AUDIO / AAC' : 'TEXT / MARKDOWN',
            style: TextStyle(fontSize: 12, color: ash, fontFamily: 'monospace'),
          ),
      ],
    ),
  );
}
