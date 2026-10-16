import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A labelled secret editor. macOS needs AppKit's secure field because Flutter's
/// native accessibility text editor is an ordinary NSTextField, even when the
/// Dart semantics value is obscured.
class SecureConnectionField extends StatefulWidget {
  const SecureConnectionField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.label,
    this.helperText,
  });

  final TextEditingController controller;
  final bool enabled;
  final String label;
  final String? helperText;

  @override
  State<SecureConnectionField> createState() => _SecureConnectionFieldState();
}

class _SecureConnectionFieldState extends State<SecureConnectionField> {
  MethodChannel? _channel;
  bool _nativeEdit = false;
  bool _focused = false;

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
    _syncNative();
  }

  void _controllerChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_nativeEdit) _syncNative();
  }

  void _syncNative() {
    unawaited(
      _channel?.invokeMethod<void>('update', {
        'text': widget.controller.text,
        'label': widget.label,
        'enabled': widget.enabled,
      }),
    );
  }

  void _created(int id) {
    _channel = MethodChannel('dev.noteagent/secure-input/$id')
      ..setMethodCallHandler((call) async {
        if (!mounted) return;
        if (call.method == 'changed' && widget.enabled) {
          final text = call.arguments as String;
          _nativeEdit = true;
          try {
            widget.controller.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
          } finally {
            _nativeEdit = false;
          }
        } else if (call.method == 'focused') {
          setState(() => _focused = call.arguments as bool);
        }
      });
    _syncNative();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final decoration = InputDecoration(
      labelText: widget.label,
      helperText: widget.helperText,
      enabled: widget.enabled,
    );
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return TextField(
        controller: widget.controller,
        enabled: widget.enabled,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        autofillHints: const [],
        keyboardType: TextInputType.visiblePassword,
        decoration: decoration,
      );
    }
    return InputDecorator(
      decoration: decoration,
      isFocused: _focused,
      isEmpty: widget.controller.text.isEmpty,
      child: SizedBox(
        height: 28,
        child: AppKitView(
          viewType: 'dev.noteagent/secure-input',
          creationParams: {'label': widget.label, 'enabled': widget.enabled},
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _created,
        ),
      ),
    );
  }
}
