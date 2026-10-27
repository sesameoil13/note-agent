part of 'connection.dart';

/// Values safe to display. Pairing codes intentionally carry a one-use secret.
class WorkspacePairingState {
  const WorkspacePairingState({
    this.role,
    this.deviceName,
    this.phase = 'unconfigured',
    this.message = '设备配对服务尚未启用。',
    this.code,
    this.verificationCode,
    this.requestDeviceName,
    this.expiresAt,
  });
  final String? role;
  final String? deviceName;
  final String phase;
  final String message;
  final String? code;
  final String? verificationCode;
  final String? requestDeviceName;
  final DateTime? expiresAt;
}

String _randomToken([int count = 32]) {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(count, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

Future<String> _digest(String value) async =>
    (await Sha256().hash(utf8.encode(value))).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
List<int> _decode(String value) => base64Url.decode(base64Url.normalize(value));
Future<String> _claimToken(Map<String, dynamic> pair) async => base64Url
    .encode(
      (await Hmac.sha256().calculateMac(
        utf8.encode('claim:${pair['id']}'),
        secretKey: SecretKey(_decode(pair['secret'] as String)),
      )).bytes,
    )
    .replaceAll('=', '');
Future<String> _verification(
  Map<String, dynamic> pair,
  String id,
  String tokenHash,
) async {
  final digest = await _digest(
    'verify:${pair['secret']}:${pair['id']}:$id:$tokenHash',
  );
  return (int.parse(digest.substring(0, 10), radix: 16) % 1000000)
      .toString()
      .padLeft(6, '0');
}

Future<SecretKey> _pairKey(Map<String, dynamic> pair) =>
    Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(_decode(pair['secret'] as String)),
      nonce: utf8.encode(pair['id'] as String),
      info: utf8.encode('note-agent/pairing/v1'),
    );

/// Pairing remains on the NoteWorkspace public connection interface. Network,
/// clock and secure storage are system boundaries; there is no vault mutation.
extension WorkspaceDevicePairing on WorkspaceConnection {
  Uri _endpoint(String value) {
    final uri = Uri.tryParse(value);
    final local =
        _allowLocalPairing &&
        (uri?.host == '127.0.0.1' || uri?.host == 'localhost') &&
        uri?.scheme == 'http';
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.scheme != 'https' && !local)) {
      throw const ConnectionFailure('配对服务地址无效，请使用 App 提供的安全配对码。');
    }
    return uri.replace(path: '');
  }

  Future<Map<String, dynamic>> _request(
    Uri endpoint,
    String path, {
    Map<String, dynamic>? body,
    String? bearer,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .openUrl(body == null ? 'GET' : 'POST', endpoint.resolve(path))
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      if (bearer != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 16384) {
          throw const ConnectionFailure('配对服务响应异常，请重试。');
        }
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map<String, dynamic>) {
        throw const ConnectionFailure('配对服务响应异常，请重试。');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = data['error'];
        throw ConnectionFailure(switch (error) {
          'pair_expired' => '配对码已过期，请在原设备重新生成。',
          'pair_rejected' => '原设备已拒绝配对，请核对后重新生成配对码。',
          'pair_already_claimed' => '配对码已被使用，请在原设备核对或重新生成。',
          'setup_invalid' => '首次启用码无效，请核对后重试。',
          'already_enrolled' => '首次启用已完成，请通过原设备配对。',
          'rate_limited' => '请求过于频繁，请稍后手动重试。',
          'active_pair_exists' => '已有配对等待处理，请先取消或等待过期。',
          'device_auth_required' || 'owner_required' => '设备授权不可用，请通过原设备重新配对。',
          _ => '配对未完成，请刷新状态或重新生成配对码。',
        }, code: error is String ? error : null);
      }
      return data;
    } on ConnectionFailure {
      rethrow;
    } catch (_) {
      throw const ConnectionFailure('配对服务暂时不可用，已保存的设置仍保留。请手动重试。');
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic>? get _device =>
      (_credentials['device'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get _outgoing =>
      (_credentials['outgoingPair'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get _incoming =>
      (_credentials['incomingPair'] as Map?)?.cast<String, dynamic>();

  Future<void> _presentPairing() async {
    final device = _device, outgoing = _outgoing, incoming = _incoming;
    if (incoming != null) {
      _pairing = WorkspacePairingState(
        phase: 'waiting',
        message: incoming['received'] == true
            ? '服务配置已安全保存，设备身份待完成确认。请刷新重试。'
            : '等待原设备核对验证码并批准；目录权限仍由本机授权。',
        deviceName: incoming['name'] as String?,
        verificationCode: await _verification(
          incoming,
          incoming['deviceId'] as String,
          await _digest(incoming['token'] as String),
        ),
      );
    } else if (outgoing != null) {
      final code = Uri(
        scheme: 'noteagent-pair',
        host: 'join',
        queryParameters: {
          'endpoint': outgoing['endpoint'] as String,
          'pair': outgoing['id'] as String,
        },
        fragment: outgoing['secret'] as String,
      ).toString();
      _pairing = WorkspacePairingState(
        role: device?['role'] as String?,
        deviceName: device?['name'] as String?,
        phase: 'inviting',
        code: code,
        expiresAt: outgoing['expiresAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(outgoing['expiresAt'] as int),
        message: '配对码仅使用一次，五分钟内有效。请直接传给自己的另一台设备。',
      );
    } else if (device != null) {
      _pairing = WorkspacePairingState(
        role: device['role'] as String,
        deviceName: device['name'] as String,
        phase: 'ready',
        message: '此设备已配对。配对只传递服务配置；笔记与附件仍由 Obsidian Sync 同步。',
      );
    } else {
      _pairing = WorkspacePairingState(
        phase: _configuredEndpoint == null ? 'unconfigured' : 'setup',
        message: _configuredEndpoint == null
            ? '配对服务尚待首次部署；本机记录可继续使用。'
            : '第一台设备启用配对，其余设备输入配对码加入。',
      );
    }
  }

  Future<void> activatePairing({
    required String setupToken,
    required String deviceName,
  }) async {
    await _ensureLoaded();
    if (_aiKey == null) {
      throw const ConnectionFailure('请先在 App 内连接阿里云百炼。');
    }
    if (_configuredEndpoint == null) {
      throw const ConnectionFailure('配对服务尚待首次部署。');
    }
    if (_device != null) {
      await refreshPairing();
      return;
    }
    final endpoint = _endpoint(_configuredEndpoint.toString());
    final pending =
        (_credentials['enrolling'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{
          'id': _randomToken(16),
          'token': _randomToken(),
          'name': deviceName.trim(),
          'endpoint': endpoint.toString(),
          'role': 'owner',
        };
    if ((pending['name'] as String).isEmpty ||
        (pending['name'] as String).length > 80) {
      throw const ConnectionFailure('请输入八十字以内的设备名称。');
    }
    await _commit({..._credentials, 'enrolling': pending});
    await _request(
      endpoint,
      '/v1/enroll',
      body: {
        'setupToken': setupToken.trim(),
        'deviceId': pending['id'],
        'deviceName': pending['name'],
        'tokenHash': await _digest(pending['token'] as String),
      },
    );
    final next = {..._credentials, 'device': pending}..remove('enrolling');
    await _commit(next);
    await _presentPairing();
  }

  Future<void> createPairing() async {
    await _ensureLoaded();
    final device = _device;
    if (device?['role'] != 'owner' || _aiKey == null) {
      throw const ConnectionFailure('请在已连接 OpenRouter 的原设备生成配对码。');
    }
    final pair =
        _outgoing ??
        <String, dynamic>{
          'id': _randomToken(16),
          'secret': _randomToken(),
          'endpoint': device!['endpoint'],
        };
    await _commit({..._credentials, 'outgoingPair': pair});
    await _presentPairing();
    final result = await _request(
      _endpoint(pair['endpoint'] as String),
      '/v1/pairs',
      bearer: device!['token'] as String,
      body: {
        'pairId': pair['id'],
        'claimHash': await _digest(await _claimToken(pair)),
      },
    );
    await _commit({
      ..._credentials,
      'outgoingPair': {...pair, 'expiresAt': result['expiresAt']},
    });
    await _presentPairing();
  }

  Future<void> joinPairing(String code, {required String deviceName}) async {
    await _ensureLoaded();
    if (_device != null) throw const ConnectionFailure('此设备已经配对。请使用尚未配对的设备。');
    try {
      final uri = Uri.parse(code.trim());
      final id = uri.queryParameters['pair'], secret = uri.fragment;
      if (uri.scheme != 'noteagent-pair' ||
          uri.host != 'join' ||
          id == null ||
          !RegExp(r'^[A-Za-z0-9_-]{8,80}$').hasMatch(id) ||
          secret.length != 43 ||
          _decode(secret).length != 32 ||
          uri.queryParameters.length != 2) {
        throw const FormatException();
      }
      final endpoint = _endpoint(uri.queryParameters['endpoint'] ?? '');
      final existing = _incoming;
      if (existing != null &&
          (existing['id'] != id ||
              existing['endpoint'] != endpoint.toString())) {
        throw const ConnectionFailure('已有配对等待处理，请先取消本次配对。');
      }
      if (deviceName.trim().isEmpty || deviceName.trim().length > 80) {
        throw const ConnectionFailure('请输入八十字以内的设备名称。');
      }
      final pair =
          existing ??
          <String, dynamic>{
            'id': id,
            'secret': secret,
            'endpoint': endpoint.toString(),
            'deviceId': _randomToken(16),
            'token': _randomToken(),
            'name': deviceName.trim(),
          };
      await _commit({..._credentials, 'incomingPair': pair});
      await _presentPairing();
      await _request(
        endpoint,
        '/v1/pairs/$id/claim',
        body: {
          'claimToken': await _claimToken(pair),
          'deviceId': pair['deviceId'],
          'deviceName': pair['name'],
          'tokenHash': await _digest(pair['token'] as String),
        },
      );
      await _presentPairing();
    } on FormatException {
      throw const ConnectionFailure('配对码不完整，请直接从原设备复制完整配对码。');
    }
  }

  Future<void> refreshPairing() async {
    await _ensureLoaded();
    final incoming = _incoming, outgoing = _outgoing, device = _device;
    if (incoming != null) {
      final result = await _request(
        _endpoint(incoming['endpoint'] as String),
        '/v1/pairs/${incoming['id']}/result',
        bearer: incoming['token'] as String,
      );
      if (result['status'] == 'waiting_approval') {
        await _presentPairing();
        return;
      }
      if (result['status'] == 'approved') {
        try {
          final encrypted = result['ciphertext'] as String;
          final aad = utf8.encode(
            '${incoming['id']}:${incoming['deviceId']}:${await _digest(incoming['token'] as String)}',
          );
          final plain = await AesGcm.with256bits().decrypt(
            SecretBox.fromConcatenation(
              _decode(encrypted),
              nonceLength: 12,
              macLength: 16,
            ),
            secretKey: await _pairKey(incoming),
            aad: aad,
          );
          final config = jsonDecode(utf8.decode(plain)) as Map;
          if (config['version'] != 1 ||
              config['pairId'] != incoming['id'] ||
              config['deviceId'] != incoming['deviceId'] ||
              config['openRouterKey'] is! String) {
            throw const FormatException();
          }
          // Persist the received secret before acknowledging its one-time removal.
          await _commit({
            ..._credentials,
            'aiKey': config['openRouterKey'],
            'aiProvider': aiProvider,
            'incomingPair': {...incoming, 'received': true},
            'device': {
              'id': incoming['deviceId'],
              'token': incoming['token'],
              'name': incoming['name'],
              'endpoint': incoming['endpoint'],
              'role': 'member',
            },
          });
          _state = const WorkspaceConnectionState(
            hasKey: true,
            message: 'OpenRouter 配置已存入系统安全存储；设备配对确认尚未完成，请刷新重试。',
          );
          await _presentPairing();
        } on ConnectionFailure {
          rethrow;
        } catch (_) {
          throw const ConnectionFailure('配对配置校验失败，现有连接仍保留。请取消后重新配对。');
        }
      } else if (result['status'] != 'completed') {
        throw const ConnectionFailure('配对状态异常，请重新配对。');
      }
      if (_aiKey == null || _device == null || _incoming?['received'] != true) {
        throw const ConnectionFailure('配对配置未保存，请重新配对。');
      }
      await _request(
        _endpoint(incoming['endpoint'] as String),
        '/v1/pairs/${incoming['id']}/ack',
        bearer: incoming['token'] as String,
        body: {},
      );
      await _commit({..._credentials}..remove('incomingPair'));
      _state = const WorkspaceConnectionState(
        hasKey: true,
        message: '已安全接收 OpenRouter 配置，待检测连接。笔记库仍由本机授权。',
      );
      await _presentPairing();
      return;
    }
    if (outgoing != null && device != null) {
      final result = await _request(
        _endpoint(outgoing['endpoint'] as String),
        '/v1/pairs/${outgoing['id']}',
        bearer: device['token'] as String,
      );
      if (result['status'] == 'completed' || result['status'] == 'rejected') {
        await _commit({..._credentials}..remove('outgoingPair'));
        await _presentPairing();
        return;
      }
      await _presentPairing();
      if (result['status'] == 'claimed' || result['status'] == 'approved') {
        _pairing = WorkspacePairingState(
          role: device['role'] as String,
          deviceName: device['name'] as String,
          phase: result['status'] == 'claimed' ? 'approval' : 'approved',
          code: _pairing.code,
          expiresAt: _pairing.expiresAt,
          requestDeviceName: result['deviceName'] as String,
          verificationCode: await _verification(
            outgoing,
            result['deviceId'] as String,
            result['tokenHash'] as String,
          ),
          message: result['status'] == 'claimed'
              ? '请在两端核对下方验证码一致，再批准。'
              : '已批准，等待另一台设备接收并保存。',
        );
      }
      return;
    }
    final enrolling = (_credentials['enrolling'] as Map?)
        ?.cast<String, dynamic>();
    final checkDevice = device ?? enrolling;
    if (checkDevice != null) {
      await _request(
        _endpoint(checkDevice['endpoint'] as String),
        '/v1/device',
        bearer: checkDevice['token'] as String,
      );
      if (enrolling != null) {
        await _commit(
          {..._credentials, 'device': enrolling}..remove('enrolling'),
        );
      }
    }
    await _presentPairing();
  }

  Future<void> approvePairing({required String verificationCode}) async {
    await refreshPairing();
    final pair = _outgoing, device = _device;
    if (pair == null ||
        device == null ||
        _pairing.phase != 'approval' ||
        verificationCode != _pairing.verificationCode) {
      throw const ConnectionFailure('请先在两台设备核对相同的验证码。');
    }
    final pending = await _request(
      _endpoint(pair['endpoint'] as String),
      '/v1/pairs/${pair['id']}',
      bearer: device['token'] as String,
    );
    if (await _verification(
          pair,
          pending['deviceId'] as String,
          pending['tokenHash'] as String,
        ) !=
        verificationCode) {
      throw const ConnectionFailure('请求设备已变化，请取消并重新配对。');
    }
    final key = _aiKey;
    if (key == null) throw const ConnectionFailure('请先连接 OpenRouter。');
    final plain = jsonEncode({
      'version': 1,
      'pairId': pair['id'],
      'deviceId': pending['deviceId'],
      'openRouterKey': key,
    });
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(plain),
      secretKey: await _pairKey(pair),
      aad: utf8.encode(
        '${pair['id']}:${pending['deviceId']}:${pending['tokenHash']}',
      ),
    );
    final ciphertext = base64Url
        .encode(box.concatenation())
        .replaceAll('=', '');
    await _request(
      _endpoint(pair['endpoint'] as String),
      '/v1/pairs/${pair['id']}/approve',
      bearer: device['token'] as String,
      body: {'ciphertext': ciphertext},
    );
    await refreshPairing();
  }

  Future<void> cancelPairing() async {
    await _ensureLoaded();
    final pair = _outgoing, device = _device;
    if (pair != null && device != null) {
      try {
        await _request(
          _endpoint(pair['endpoint'] as String),
          '/v1/pairs/${pair['id']}/reject',
          bearer: device['token'] as String,
          body: {},
        );
      } on ConnectionFailure catch (error) {
        if (error.code != 'pair_not_found' &&
            error.code != 'pair_expired' &&
            (pair['expiresAt'] == null ||
                DateTime.now().millisecondsSinceEpoch <
                    (pair['expiresAt'] as int))) {
          rethrow;
        }
      }
    }
    // Keep the received Key, but discard an incompletely acknowledged identity.
    final next = {..._credentials}
      ..remove('outgoingPair')
      ..remove('incomingPair');
    if (_incoming != null && _device?['id'] == _incoming?['deviceId']) {
      next.remove('device');
    }
    await _commit(next);
    await _presentPairing();
  }
}
