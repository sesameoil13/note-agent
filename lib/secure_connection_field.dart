import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// macOS edits secrets in an AppKit sheet: the Flutter text editor exposes its
/// raw native AX value, while this SDK's embedded AppKit views lack an AX bridge.
class SecureConnectionField extends StatefulWidget {
  const SecureConnectionField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.label,
    this.actionLabel,
    this.helperText,
  });

  final TextEditingController controller;
  final bool enabled;
  final String label;
  final String? actionLabel;
  final String? helperText;

  @override
  State<SecureConnectionField> createState() => _SecureConnectionFieldState();
}

class _SecureConnectionFieldState extends State<SecureConnectionField> {
  static const _channel = MethodChannel('dev.noteagent/secure-input');
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void didUpdateWidget(SecureConnectionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
    }
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _edit() async {
    if (!widget.enabled || _editing) return;
    setState(() => _editing = true);
    try {
      final text = await _channel.invokeMethod<String>('edit', {
        'label': widget.label,
        'text': widget.controller.text,
      });
      if (mounted && text != null && text.trim().isNotEmpty) {
        widget.controller.text = text;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('安全输入暂时不可用，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return TextField(
        controller: widget.controller,
        enabled: widget.enabled,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        autofillHints: const [],
        keyboardType: TextInputType.visiblePassword,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helperText,
        ),
      );
    }
    final enabled = widget.enabled && !_editing;
    final label = widget.actionLabel ?? '填写 ${widget.label}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          container: true,
          label: label,
          button: true,
          enabled: enabled,
          onTap: enabled ? _edit : null,
          excludeSemantics: true,
          child: OutlinedButton.icon(
            onPressed: enabled ? _edit : null,
            icon: const Icon(Icons.lock_outline),
            label: Text(label),
          ),
        ),
        if (widget.controller.text.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('已填写，尚未提交。'),
        ],
        if (widget.helperText != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.helperText!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
