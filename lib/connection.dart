import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';

import 'first_run.dart';
part 'pairing.dart';
part 'budget_connection.dart';
part 'todo_connection.dart';
part 'text_model.dart';
part 'audio_model.dart';

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
/// Bailian's AI service (ADR 0003), saved with the key so a device that
/// still holds an old OpenRouter key is asked to reconnect.
const aiProvider = 'bailian-cn';
const bailianApiBase = 'https://dashscope.aliyuncs.com/compatible-mode/v1/';

/// Checks a key by listing models, which Bailian does not bill (issue #34).
class AiKeyCheck {
  AiKeyCheck({Uri? endpoint})
    : endpoint = endpoint ?? Uri.parse(bailianApiBase).resolve('models');
  final Uri endpoint;

  Future<void> verify(String key) async {
    if (key.length < 16 || key.length > 256 || RegExp(r'\s').hasMatch(key)) {
      throw const ConnectionFailure('请输入完整的阿里云百炼 API Key。');
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
        throw const ConnectionFailure('阿里云百炼暂时无法连接，请稍后手动重试。');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 1048576) {
          throw const ConnectionFailure('连接检测响应异常，请稍后重试。');
        }
      }
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map || body['data'] is! List) {
        throw const ConnectionFailure('连接检测响应异常，请稍后重试。');
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
    this.message = '尚未连接阿里云百炼。',
  });
  final bool hasKey;
  final bool connectionVerified;
  final String message;
}

/// Connection operations exposed through NoteWorkspace; no vault authorization is transferred.
class WorkspaceConnection {
  WorkspaceConnection({
    required SecureCredentialStore secureStore,
    AiKeyCheck? keyCheck,
    Uri? pairingEndpoint,
    Uri? textApiBase,
    bool allowLocalPairingForTests = false,
    // Lets a test act as an original device still on the old version-1 format.
    @visibleForTesting int pairingConfigVersionForTests = 2,
  }) : _store = secureStore,
       _pairingConfigVersion = pairingConfigVersionForTests,
       _keyCheck = keyCheck ?? AiKeyCheck(),
       _textApiBase = textApiBase ?? Uri.parse(bailianApiBase),
       _configuredEndpoint = pairingEndpoint,
       _allowLocalPairing = allowLocalPairingForTests {
    final production = Uri.parse(bailianApiBase);
    final loopback =
        allowLocalPairingForTests &&
        _textApiBase.scheme == 'http' &&
        ['127.0.0.1', 'localhost', '::1'].contains(_textApiBase.host) &&
        _textApiBase.userInfo.isEmpty &&
        !_textApiBase.hasQuery &&
        !_textApiBase.hasFragment;
    if (_textApiBase != production && !loopback) {
      throw ArgumentError(
        'Text API endpoint must be the fixed HTTPS production endpoint.',
      );
    }
  }

  /// The pairing service the App ships with (T12 预置服务入口). A
  /// `PAIRING_ENDPOINT` dart-define overrides it, e.g. for a staging Worker.
  static const presetPairingEndpoint =
      'https://note-agent-pairing.sesameoil13.workers.dev';
  factory WorkspaceConnection.platform() {
    const endpoint = String.fromEnvironment(
      'PAIRING_ENDPOINT',
      defaultValue: presetPairingEndpoint,
    );
    return WorkspaceConnection(
      secureStore: PlatformSecureCredentialStore(),
      pairingEndpoint: Uri.tryParse(
        endpoint.isEmpty ? presetPairingEndpoint : endpoint,
      ),
      allowLocalPairingForTests:
          kDebugMode && const bool.fromEnvironment('PAIRING_ALLOW_LOOPBACK'),
    );
  }
  final Uri? _configuredEndpoint;
  final Uri _textApiBase;
  Uri get textApiBase => _textApiBase;
  final bool _allowLocalPairing;
  final int _pairingConfigVersion;
  bool _loaded = false;
  WorkspacePairingState _pairing = const WorkspacePairingState();
  WorkspacePairingState get pairing => _pairing;
  bool get pairingServiceConfigured => _configuredEndpoint != null;
  Uri? get pairingEndpoint => _configuredEndpoint;
  final SecureCredentialStore _store;
  final AiKeyCheck _keyCheck;
  Map<String, dynamic> _credentials = {};
  WorkspaceConnectionState _state = const WorkspaceConnectionState();
  WorkspaceConnectionState get state => _state;

  /// The Bailian key, or null when none (or only an old OpenRouter key) is kept.
  String? get _aiKey =>
      _credentials['aiProvider'] == aiProvider &&
          _credentials['aiKey'] is String
      ? _credentials['aiKey'] as String
      : null;

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
        hasKey: _aiKey != null,
        message: _aiKey != null
            ? 'Key 已保存在系统安全存储，待检测连接。'
            // The old OpenRouter key stays on this device only (ADR 0003).
            : _credentials['openRouterKey'] is String
            ? 'AI 服务已改为阿里云百炼，请重新连接。'
            : '尚未连接阿里云百炼。',
      );
    } catch (_) {
      throw const ConnectionFailure('系统安全存储暂时不可用，请解锁设备后重试。');
    }
  }

  Future<void> connectAi(String enteredKey) async {
    await _ensureLoaded();
    final key = enteredKey.trim();
    try {
      await _keyCheck.verify(key);
      final next = {..._credentials, 'aiKey': key, 'aiProvider': aiProvider};
      await _commit(next);
      _state = const WorkspaceConnectionState(
        hasKey: true,
        connectionVerified: true,
        message: '阿里云百炼连接成功。Key 已存入系统安全存储；检测未调用收费模型。',
      );
    } on ConnectionFailure catch (error) {
      _state = WorkspaceConnectionState(
        hasKey: _aiKey != null,
        message: error.message,
      );
      rethrow;
    } catch (_) {
      throw const ConnectionFailure('Key 未能存入系统安全存储，请解锁设备后重试。');
    }
  }

  Future<void> checkAi() async {
    await _ensureLoaded();
    final key = _aiKey;
    if (key == null) throw const ConnectionFailure('请先在 App 内连接阿里云百炼。');
    await connectAi(key);
  }

  /// First-run answers are per device and exist before any vault is chosen,
  /// so they are kept with the device's connection state.
  Future<FirstRunAnswers?> loadFirstRun() async {
    await _ensureLoaded();
    final stored = _credentials['firstRun'];
    return stored is Map
        ? FirstRunAnswers.fromJson(Map<String, dynamic>.from(stored))
        : null;
  }

  Future<void> saveFirstRun(FirstRunAnswers answers) async {
    await _ensureLoaded();
    await _commit({..._credentials, 'firstRun': answers.toJson()});
  }

  Future<void> disconnectAi() async {
    await _ensureLoaded();
    final next = {..._credentials}
      ..remove('aiKey')
      ..remove('aiProvider');
    await _commit(next);
    _state = const WorkspaceConnectionState(message: '已从本机移除阿里云百炼 Key。');
  }
}
