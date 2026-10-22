import 'package:flutter/material.dart';

import 'note_workspace.dart';

String reminderTimeLabel(DateTime time) {
  final t = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  var label =
      '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  if (t.second != 0 || t.millisecond != 0 || t.microsecond != 0) {
    label += ':${two(t.second)}';
    if (t.millisecond != 0 || t.microsecond != 0) {
      label += '.${t.millisecond.toString().padLeft(3, '0')}';
      if (t.microsecond != 0) label += t.microsecond.toString().padLeft(3, '0');
    }
  }
  return label;
}

class ReminderScreen extends StatefulWidget {
  const ReminderScreen({super.key, required this.workspace});
  final NoteWorkspace workspace;
  @override
  State<ReminderScreen> createState() => _ReminderScreenState();
}

class _ReminderScreenState extends State<ReminderScreen> {
  late final List<TextEditingController> defaults;
  bool busy = false;
  String? message;
  @override
  void initState() {
    super.initState();
    final d = widget.workspace.reminderDefaults;
    defaults =
        [
              d.dateMinute,
              d.morningMinute,
              d.afternoonMinute,
              d.eveningMinute,
              d.tomorrowMinute,
            ]
            .map(
              (v) => TextEditingController(
                text:
                    '${(v ~/ 60).toString().padLeft(2, '0')}:${(v % 60).toString().padLeft(2, '0')}',
              ),
            )
            .toList();
  }

  @override
  void dispose() {
    for (final c in defaults) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      message = e is ArgumentError
          ? '${e.message}'
          : e is StateError
          ? e.message
          : '操作尚未完成，请重试。';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> saveDefaults() => run(() async {
    final minutes = defaults.map((c) {
      final m = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$')
          .firstMatch(c.text.trim());
      if (m == null) throw ArgumentError('请以 HH:mm 输入 00:00–23:59 的时间。');
      return int.parse(m[1]!) * 60 + int.parse(m[2]!);
    }).toList();
    await widget.workspace.setReminderDefaults(
      ReminderDefaults(
        dateMinute: minutes[0],
        morningMinute: minutes[1],
        afternoonMinute: minutes[2],
        eveningMinute: minutes[3],
        tomorrowMinute: minutes[4],
      ),
    );
    message = '默认时间已保存，仅影响新增事项。';
  });
  Future<void> preview() async {
    final plan = widget.workspace.previewReminderDefaults();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('预览现有默认提醒'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('仅调整下列默认计划；明确指定的时间保持原样。'),
                if (plan.changes.isEmpty) const Text('没有需要调整的提醒。'),
                for (final c in plan.changes)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      '${c.text}\n${reminderTimeLabel(c.previousTime)} → ${reminderTimeLabel(c.time)}',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          if (plan.changes.isNotEmpty)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('确认应用 ${plan.changes.length} 项'),
            ),
        ],
      ),
    );
    if (confirmed == true) {
      await run(() => widget.workspace.applyReminderDefaults(plan));
    }
  }

  Future<void> edit(WorkspaceReminder reminder) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _ReminderTimeDialog(reminder: reminder),
    );
    if (value == null || !mounted) return;
    await run(() async {
      final entered = RegExp(
        r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?$',
      ).firstMatch(value.trim());
      final t = DateTime.tryParse(value.trim());
      final fraction = (entered?[7] ?? '').padRight(6, '0');
      if (entered == null ||
          t == null ||
          t.year != int.parse(entered[1]!) ||
          t.month != int.parse(entered[2]!) ||
          t.day != int.parse(entered[3]!) ||
          t.hour != int.parse(entered[4]!) ||
          t.minute != int.parse(entered[5]!) ||
          t.second != (int.tryParse(entered[6] ?? '') ?? 0) ||
          t.millisecond * 1000 + t.microsecond != int.parse(fraction)) {
        throw ArgumentError('请填写有效的年月日和时间。');
      }
      await widget.workspace.setActionReminderTime(
        reminder.noteId,
        reminder.actionId,
        t,
      );
    });
  }

  String get permissionLabel =>
      switch (widget.workspace.notificationPermission) {
        NotificationPermission.allowed => '系统通知已允许',
        NotificationPermission.denied => '系统通知未允许，请在系统设置中开启后重试。',
        NotificationPermission.notDetermined => '尚未请求通知权限',
        NotificationPermission.unknown => '系统通知状态未能核对',
        NotificationPermission.unavailable => '通知功能尚未连接当前平台',
      };
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('提醒与默认时间')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(permissionLabel),
        if (widget.workspace.notificationError != null)
          Text(widget.workspace.notificationError!),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => run(widget.workspace.requestNotificationPermission),
              child: const Text('允许系统通知'),
            ),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => run(widget.workspace.reconcileReminders),
              child: const Text('重新核对系统通知'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          '默认时间',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const Text('行动已确认而时间未确认时仍使用默认提醒。已过期的默认时间会立即提醒一次。'),
        for (var i = 0; i < defaults.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextField(
              enabled: !busy,
              controller: defaults[i],
              decoration: InputDecoration(
                labelText: const ['仅有日期', '上午', '下午', '晚上', '无日期／时间待确认'][i],
                hintText: 'HH:mm',
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy ? null : saveDefaults,
          child: const Text('保存默认时间（仅新增事项）'),
        ),
        OutlinedButton(
          onPressed: busy ? null : preview,
          child: const Text('预览应用到现有默认提醒'),
        ),
        if (message != null) Text(message!),
        const Divider(height: 40),
        const Text(
          '本机提醒计划',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const Text('系统接受计划不代表已实际显示通知；可在此核对或调整时间。'),
        if (widget.workspace.reminders.isEmpty) const Text('暂无已确认行动的提醒。'),
        for (final r in widget.workspace.reminders)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.text),
                  Text(reminderTimeLabel(r.time)),
                  Text(switch (r.status) {
                    ReminderStatus.pending => '等待安排',
                    ReminderStatus.scheduled => '系统已接受计划',
                    ReminderStatus.elapsed => '提醒时间已过',
                    ReminderStatus.blocked => '等待通知权限',
                    ReminderStatus.failed => '安排未完成，可重试',
                  }),
                  if (r.timeNeedsConfirmation) const Text('时间待确认，当前使用默认提醒'),
                  if (r.error != null) Text(r.error!),
                  TextButton(
                    onPressed: busy ? null : () => edit(r),
                    child: const Text('修改提醒时间'),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class _ReminderTimeDialog extends StatefulWidget {
  const _ReminderTimeDialog({required this.reminder});
  final WorkspaceReminder reminder;
  @override
  State<_ReminderTimeDialog> createState() => _ReminderTimeDialogState();
}

class _ReminderTimeDialogState extends State<_ReminderTimeDialog> {
  late final input = TextEditingController(
    text: reminderTimeLabel(widget.reminder.time),
  );
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.reminder.text),
    content: TextField(
      controller: input,
      autofocus: true,
      decoration: const InputDecoration(labelText: '提醒时间（YYYY-MM-DD HH:mm）'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, input.text),
        child: const Text('确认新时间'),
      ),
    ],
  );
}
