import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';
part 'pairing.dart';

/// OS boundary. The entire credential envelope belongs in the system secure store.
abstract interface class SecureCredentialStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class PlatformSecureCredentialStore implements SecureCredentialStore {
  static const _channel = MethodChannel('dev.noteagent/credentials');
  static const _slot = String.fromEnvironment(
    'DEVICE_SLOT',
    defaultValue: 'default',
  );
  @override
  Future<String?> read() =>
      _channel.invokeMethod<String>('read', {'slot': _slot});
  @override
  Future<void> write(String value) =>
      _channel.invokeMethod<void>('write', {'value': value, 'slot': _slot});
  @override
  Future<void> delete() =>
      _channel.invokeMethod<void>('delete', {'slot': _slot});
}

class ConnectionFailure implements Exception {
  const ConnectionFailure(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

/// OpenRouter system boundary: this operation only reads key metadata.
class OpenRouterKeyCheck {
  OpenRouterKeyCheck({Uri? endpoint})
    : endpoint = endpoint ?? Uri.https('openrouter.ai', '/api/v1/key');
  final Uri endpoint;

  Future<void> verify(String key) async {
    if (key.length < 16 || key.length > 256 || RegExp(r'\s').hasMatch(key)) {
      throw const ConnectionFailure('请输入完整的 OpenRouter API Key。');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(endpoint)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const ConnectionFailure('Key 无效或已被撤销，请在 App 内重新连接。');
      }
      if (response.statusCode != 200) {
        throw const ConnectionFailure('OpenRouter 暂时无法连接，请稍后手动重试。');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) {
          throw const ConnectionFailure('连接检测响应异常，请稍后重试。');
        }
      }
      final body = jsonDecode(utf8.decode(bytes));
      final data = body is Map ? body['data'] : null;
      if (data is! Map) throw const ConnectionFailure('连接检测响应异常，请稍后重试。');
      if (data['is_management_key'] == true ||
          data['is_provisioning_key'] == true) {
        throw const ConnectionFailure('请使用普通模型 API Key，不要使用账户管理 Key。');
      }
    } on ConnectionFailure {
      rethrow;
    } catch (_) {
      throw const ConnectionFailure('网络或服务暂时不可用，已保存的设置仍保留。请手动重试。');
    } finally {
      client.close(force: true);
    }
  }
}

class WorkspaceConnectionState {
  const WorkspaceConnectionState({
    this.hasKey = false,
    this.connectionVerified = false,
    this.message = '尚未连接 OpenRouter。',
  });
  final bool hasKey;
  final bool connectionVerified;
  final String message;
}

/// Connection operations exposed through NoteWorkspace; no vault authorization is transferred.
class WorkspaceConnection {
  WorkspaceConnection({
    required SecureCredentialStore secureStore,
    OpenRouterKeyCheck? openRouter,
    Uri? pairingEndpoint,
    bool allowLocalPairingForTests = false,
  }) : _store = secureStore,
       _openRouter = openRouter ?? OpenRouterKeyCheck(),
       _configuredEndpoint = pairingEndpoint,
       _allowLocalPairing = allowLocalPairingForTests;
  factory WorkspaceConnection.platform() {
    const endpoint = String.fromEnvironment('PAIRING_ENDPOINT');
    return WorkspaceConnection(
      secureStore: PlatformSecureCredentialStore(),
      pairingEndpoint: endpoint.isEmpty ? null : Uri.tryParse(endpoint),
      allowLocalPairingForTests:
          kDebugMode && const bool.fromEnvironment('PAIRING_ALLOW_LOOPBACK'),
    );
  }
  final Uri? _configuredEndpoint;
  final bool _allowLocalPairing;
  bool _loaded = false;
  WorkspacePairingState _pairing = const WorkspacePairingState();
  WorkspacePairingState get pairing => _pairing;
  bool get pairingServiceConfigured => _configuredEndpoint != null;
  final SecureCredentialStore _store;
  final OpenRouterKeyCheck _openRouter;
  Map<String, dynamic> _credentials = {};
  WorkspaceConnectionState _state = const WorkspaceConnectionState();
  WorkspaceConnectionState get state => _state;

  Future<void> _ensureLoaded() async {
    if (!_loaded) await restore();
  }

  Future<void> _commit(Map<String, dynamic> next) async {
    try {
      await _store.write(jsonEncode(next));
    } catch (_) {
      throw const ConnectionFailure('系统安全存储暂时不可用，请解锁设备后重试。');
    }
    _credentials = next;
  }

  Future<void> restore() async {
    try {
      final value = await _store.read();
      _credentials = value == null
          ? {}
          : Map<String, dynamic>.from(jsonDecode(value) as Map);
      await _presentPairing();
      _loaded = true;
      _state = WorkspaceConnectionState(
        hasKey: _credentials['openRouterKey'] is String,
        message: _credentials['openRouterKey'] is String
            ? 'Key 已保存在系统安全存储，待检测连接。'
            : '尚未连接 OpenRouter。',
      );
    } catch (_) {
      throw const ConnectionFailure('系统安全存储暂时不可用，请解锁设备后重试。');
    }
  }

  Future<void> connectOpenRouter(String enteredKey) async {
    await _ensureLoaded();
    final key = enteredKey.trim();
    try {
      await _openRouter.verify(key);
      final next = {..._credentials, 'openRouterKey': key};
      await _commit(next);
      _state = const WorkspaceConnectionState(
        hasKey: true,
        connectionVerified: true,
        message: 'OpenRouter 连接成功。Key 已存入系统安全存储；检测未调用收费模型。',
      );
    } on ConnectionFailure catch (error) {
      _state = WorkspaceConnectionState(
        hasKey: _credentials['openRouterKey'] is String,
        message: error.message,
      );
      rethrow;
    } catch (_) {
      throw const ConnectionFailure('Key 未能存入系统安全存储，请解锁设备后重试。');
    }
  }

  Future<void> checkOpenRouter() async {
    await _ensureLoaded();
    final key = _credentials['openRouterKey'] as String?;
    if (key == null) throw const ConnectionFailure('请先在 App 内连接 OpenRouter。');
    await connectOpenRouter(key);
  }

  Future<void> disconnectOpenRouter() async {
    await _ensureLoaded();
    final next = {..._credentials}..remove('openRouterKey');
    await _commit(next);
    _state = const WorkspaceConnectionState(message: '已从本机移除 OpenRouter Key。');
  }
}
