import 'package:flutter/material.dart';

import 'note_workspace.dart';
import 'reminder_screen.dart' show reminderTimeLabel;

/// 归档 and 回收站 in one place. The 回收站 is never emptied automatically;
/// restore is per item and never replaces a same-named note.
class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key, required this.workspace});
  final NoteWorkspace workspace;
  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  bool busy = false;
  String? message;
  NoteWorkspace get w => widget.workspace;

  Future<void> _run(Future<String?> Function() operation) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = await operation();
      if (mounted) setState(() => message = result);
    } catch (e) {
      if (mounted) setState(() => message = e is StateError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<DateTime?> _pickTime() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
      helpText: '新的提醒日期',
    );
    if (day == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
      helpText: '新的提醒时间',
    );
    if (time == null) return null;
    return DateTime(day.year, day.month, day.day, time.hour, time.minute);
  }

  Widget _section(String title, String hint) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        Text(hint, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final decisions = w.reminderDecisions;
    final archived = w.archivedNotes;
    final bin = w.recycleBin;
    String title(String noteId) =>
        w.notes.where((n) => n.id == noteId).firstOrNull?.title ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('归档与回收站')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (message != null) Text(message!),
          if (decisions.isNotEmpty) ...[
            _section('过期提醒待决定', '这些提醒在回收站期间已过时间，恢复后不会自动响起。'),
            for (final d in decisions)
              ListTile(
                title: Text(d.text),
                subtitle: Text(
                  '${title(d.noteId)} · 原定 ${reminderTimeLabel(d.missedTime)}',
                ),
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              final time = await _pickTime();
                              if (time == null) return;
                              await _run(() async {
                                await w.decideRestoredReminder(
                                  d.noteId,
                                  d.actionId,
                                  time,
                                );
                                return '已重新安排提醒。';
                              });
                            },
                      child: const Text('重新安排…'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _run(() async {
                              await w.decideRestoredReminder(
                                d.noteId,
                                d.actionId,
                                null,
                              );
                              return '事项保留，不再提醒。';
                            }),
                      child: const Text('不再提醒'),
                    ),
                  ],
                ),
              ),
          ],
          _section('已归档', '归档的笔记仍在笔记库中，提醒照常。'),
          if (archived.isEmpty) const Text('没有归档的笔记。'),
          for (final note in archived)
            ListTile(
              title: Text(note.title),
              trailing: TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        await w.unarchiveNote(note.id);
                        return '已放回最近记录。';
                      }),
                child: const Text('取消归档'),
              ),
            ),
          _section('回收站', '回收站不会自动清空。删除时提醒已取消；来源文字与附件仍保留在笔记库。'),
          if (bin.isEmpty) const Text('回收站是空的。'),
          for (final item in bin)
            ListTile(
              title: Text(item.title),
              subtitle: Text('删除于 ${reminderTimeLabel(item.deletedAt)}'),
              trailing: TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        final note = await w.restoreNote(item.noteId);
                        return note.titleCollision
                            ? '已恢复为「${note.title}」：原标题已被其他笔记使用。'
                            : '已恢复「${note.title}」。';
                      }),
                child: const Text('恢复'),
              ),
            ),
        ],
      ),
    );
  }
}
