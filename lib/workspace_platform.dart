import 'dart:io';

import 'package:flutter/services.dart';

import 'vault_storage.dart';

class WorkspaceLocation {
  const WorkspaceLocation(
    this.localDirectory,
    this.vaultDirectory, {
    this.vaultStorage,
    this.deviceInfo,
    this.authorizationError,
  });

  final Directory localDirectory;
  final Directory? vaultDirectory;
  final VaultStorage? vaultStorage;
  final String? deviceInfo;
  final String? authorizationError;
  bool get hasVault => vaultDirectory != null || vaultStorage != null;
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

  bool get supportsSourceFiles =>
      Platform.isMacOS || Platform.isWindows || Platform.isAndroid;

  /// Selected paths are ephemeral grants. The workspace copies the source
  /// privately before the UI releases the system access.
  Future<File?> chooseSourceFile({
    bool pdfOnly = false,
    bool wordOnly = false,
    bool audioOnly = false,
  }) async {
    if ([pdfOnly, wordOnly, audioOnly].where((v) => v).length > 1) {
      throw ArgumentError('一次只能选择一种来源文件类型。');
    }
    final path = await _channel.invokeMethod<String>('chooseSourceFile', {
      'pdfOnly': pdfOnly,
      'wordOnly': wordOnly,
      'audioOnly': audioOnly,
    });
    return path == null ? null : File(path);
  }

  Future<void> releaseSourceFile(File file) =>
      _channel.invokeMethod<void>('releaseSourceFile', {'path': file.path});

  Future<void> revealLocalSource(String path) =>
      _channel.invokeMethod<void>('revealLocalSource', {'path': path});

  /// Desktop only. A one-off, read-only pick for the backup comparison; it is
  /// never persisted and never becomes the App's vault.
  bool get supportsFolderComparison => Platform.isMacOS;

  Future<Directory?> chooseFolderForReading(String title) async {
    final path = await _channel.invokeMethod<String>('chooseFolder', {
      'title': title,
    });
    return path == null ? null : Directory(path);
  }

  Future<void> openSyncPlans() => _channel.invokeMethod<void>('openSyncPlans');

  Future<void> openInObsidian(String reference) {
    final uri = Uri.tryParse(reference);
    if (uri?.scheme == 'noteagent-vault') {
      return _channel.invokeMethod<void>('openInObsidian', {
        'vaultUri': uri!.queryParameters['vault'],
        'relativePath': uri.queryParameters['file'],
      });
    }
    return _channel.invokeMethod<void>('openInObsidian', {'path': reference});
  }

  WorkspaceLocation _location(Map<String, String>? data) {
    if (data == null || data['localDirectory'] == null) {
      throw PlatformException(code: 'location', message: '无法打开本机存储位置。');
    }
    return WorkspaceLocation(
      Directory(data['localDirectory']!),
      data['vaultDirectory'] == null
          ? null
          : Directory(data['vaultDirectory']!),
      vaultStorage: data['vaultUri'] == null
          ? null
          : AndroidVaultStorage(data['vaultUri']!, data['vaultName'] ?? '笔记库'),
      deviceInfo: data['deviceInfo'],
      authorizationError: data['authorizationError'],
    );
  }
}

/// SAF content-tree access stays on Android's ContentResolver boundary.
class AndroidVaultStorage implements VaultStorage, BinaryVaultStorage {
  AndroidVaultStorage(this.identity, this.displayName);
  static const _channel = MethodChannel('dev.noteagent/workspace');
  @override
  final String identity;
  @override
  final String displayName;

  String _safe(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FileSystemException('笔记位置必须位于当前笔记库内。', path);
    }
    return path;
  }

  @override
  String reference(String relativePath) => Uri(
    scheme: 'noteagent-vault',
    queryParameters: {'vault': identity, 'file': _safe(relativePath)},
  ).toString();
  @override
  String relativePath(String reference) {
    final uri = Uri.parse(reference);
    if (uri.scheme != 'noteagent-vault' ||
        uri.queryParameters['vault'] != identity) {
      throw FileSystemException('笔记不在当前笔记库中。', reference);
    }
    return _safe(uri.queryParameters['file']!);
  }

  Future<T?> _invoke<T>(
    String method,
    String path, [
    Map<String, Object?> extra = const {},
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, {
        'vaultUri': identity,
        'relativePath': _safe(path),
        ...extra,
      });
    } on PlatformException catch (error) {
      throw FileSystemException(error.message ?? '笔记库操作失败，请重新授权后重试。', identity);
    }
  }

  @override
  Future<bool> exists(String relativePath) async =>
      await _invoke<bool>('vaultExists', relativePath) ?? false;
  @override
  Future<String> readText(String relativePath) async {
    final text = await _invoke<String>('vaultReadText', relativePath);
    if (text == null) throw FileSystemException('笔记文件不存在。', relativePath);
    return text;
  }

  @override
  Future<void> publishText(
    String relativePath,
    String text,
    String operationId,
  ) => _invoke<void>('vaultPublishText', relativePath, {
    'text': text,
    'operationId': operationId,
  });

  @override
  Future<void> publishFile(
    String relativePath,
    File original,
    String operationId,
  ) => _invoke<void>('vaultPublishFile', relativePath, {
    'sourcePath': original.path,
    'operationId': operationId,
  });
  @override
  Future<List<String>> listNotePaths() async {
    final paths = await _invoke<List<Object?>>(
      'vaultListNotePaths',
      '__list__',
    );
    return paths?.cast<String>() ?? [];
  }

  @override
  Future<void> replaceText(
    String relativePath,
    String expectedText,
    String text,
    String operationId,
  ) => _invoke<void>('vaultReplaceText', relativePath, {
    'expectedText': expectedText,
    'text': text,
    'operationId': operationId,
  });
  @override
  Future<void> deleteText(String relativePath, String expectedText) =>
      _invoke<void>('vaultDeleteText', relativePath, {
        'expectedText': expectedText,
      });
  @override
  Future<void> deleteFile(String relativePath) =>
      _invoke<void>('vaultDeleteFile', relativePath);
  @override
  Future<DateTime?> modifiedTime(String relativePath) async {
    final millis = await _invoke<int>('vaultModifiedTime', relativePath);
    return millis == null || millis <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis);
  }
}
