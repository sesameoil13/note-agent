import 'dart:io';

import 'package:flutter/services.dart';

class WorkspaceLocation {
  const WorkspaceLocation(this.localDirectory, this.vaultDirectory);

  final Directory localDirectory;
  final Directory? vaultDirectory;
}

/// System boundary: directory authorization and external application opening.
class WorkspacePlatform {
  static const _channel = MethodChannel('dev.noteagent/workspace');

  Future<WorkspaceLocation> restoreLocation() async => _location(
    await _channel.invokeMapMethod<String, String>('restoreLocation'),
  );

  Future<WorkspaceLocation?> chooseLocation() async {
    final result = await _channel.invokeMapMethod<String, String>(
      'chooseLocation',
    );
    return result == null ? null : _location(result);
  }

  Future<void> openInObsidian(String path) =>
      _channel.invokeMethod<void>('openInObsidian', {'path': path});

  WorkspaceLocation _location(Map<String, String>? data) {
    if (data == null || data['localDirectory'] == null) {
      throw PlatformException(code: 'location', message: '无法打开本机存储位置。');
    }
    return WorkspaceLocation(
      Directory(data['localDirectory']!),
      data['vaultDirectory'] == null
          ? null
          : Directory(data['vaultDirectory']!),
    );
  }
}
