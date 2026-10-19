part of 'connection.dart';

const textModelId = 'deepseek/deepseek-v4.1-flash';
Map<String, dynamic> textModelPayload(
  String sourceId,
  String text,
  Map<String, dynamic> q,
) => {
  'model': textModelId,
  'max_tokens': 1024,
  'stream': false,
  'reasoning': {'effort': 'none'},
  'provider': {
    'only': [q['provider']],
    'allow_fallbacks': false,
    'require_parameters': true,
    'max_price': {
      'prompt': (q['promptNano'] as int) / 1000,
      'completion': (q['completionNano'] as int) / 1000,
    },
  },
  'messages': [
    {
      'role': 'system',
      'content': '整理简体中文普通笔记，保留原意，不添加事实。返回简短中文标题与正文。若涉及行动安排或不能确定为普通笔记，kind=review；不得创建待办、链接、日期或额外操作。来源ID必须原样返回。',
    },
    {
      'role': 'user',
      'content': jsonEncode({'sourceId': sourceId, 'text': text}),
    },
  ],
  'response_format': {
    'type': 'json_schema',
    'json_schema': {
      'name': 'ordinary_note',
      'strict': true,
      'schema': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['sourceId', 'kind', 'title', 'body'],
        'properties': {
          'sourceId': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['ordinary', 'review'],
          },
          'title': {'type': 'string'},
          'body': {'type': 'string'},
        },
      },
    },
  },
};

class TextModelReply {
  const TextModelReply(this.data);
  final Map<String, dynamic> data;
  String? get generationId =>
      data['id'] is String ? data['id'] as String : null;
  int? get usdNanos {
    final usage = data['usage'];
    final cost = usage is Map ? usage['cost'] : null;
    return cost is num && cost.isFinite && cost >= 0 && cost <= 1000
        ? (cost * 1e9).ceil()
        : null;
  }

  Map<String, dynamic> validated(String sourceId) {
    if (data['model'] != textModelId) {
      throw const ConnectionFailure('返回模型与固定型号不符，结果未应用。');
    }
    final choices = data['choices'];
    if (choices is! List ||
        choices.length != 1 ||
        choices.first is! Map ||
        choices.first['finish_reason'] != 'stop') {
      throw const ConnectionFailure('模型结果不完整，原文已保留，费用仍按实际记录。');
    }
    final content = (choices.first['message'] as Map?)?['content'];
    final result = content is String ? jsonDecode(content) : null;
    if (result is! Map<String, dynamic> ||
        result.length != 4 ||
        result['sourceId'] != sourceId ||
        !['ordinary', 'review'].contains(result['kind']) ||
        result['title'] is! String ||
        result['body'] is! String) {
      throw const ConnectionFailure('模型结果无法核对来源或格式，未改写笔记。');
    }
    final title = result['title'] as String, body = result['body'] as String;
    if (title.trim().isEmpty ||
        title.length > 60 ||
        RegExp(r'[\r\n\x00-\x1f]').hasMatch(title) ||
        !RegExp(r'[\u4e00-\u9fff]').hasMatch(title) ||
        RegExp(r'\d{4}[-/]\d').hasMatch(title) ||
        body.trim().isEmpty ||
        body.length > 12000 ||
        body.contains('\u0000')) {
      throw const ConnectionFailure('模型标题或正文不符合约定，未改写笔记。');
    }
    return result;
  }
}

class TextNetworkFailure implements Exception {
  const TextNetworkFailure(
    this.message, {
    this.recoverable = false,
    this.generationId,
  });
  final String message;
  final bool recoverable;
  final String? generationId;
}

extension WorkspaceTextNetwork on WorkspaceConnection {
  Future<TextModelReply> sendReservedText(
    String attemptId,
    Map<String, dynamic> payload,
  ) async {
    await _ensureLoaded();
    final key = _credentials['openRouterKey'] as String?;
    if (key == null) {
      throw const ConnectionFailure(
        '请先在 App 连接 OpenRouter。',
        code: 'credentials',
      );
    }
    await requestSharedBudget('/v1/budget/attempt/$attemptId/send', body: {});
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .postUrl(_textApiBase.resolve('chat/completions'))
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 131072) {
          throw const TextNetworkFailure('模型响应超出安全上限，原文保留。');
        }
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const TextNetworkFailure('Key 无效或权限不足，请在 App 重新连接。');
      }
      if (response.statusCode == 402) {
        throw const TextNetworkFailure('OpenRouter 余额不足，请在官网核对；App 不自动充值。');
      }
      if (response.statusCode != 200) {
        throw TextNetworkFailure(
          '模型服务暂时不可用，原文与费用预留保留。',
          recoverable: [
            408,
            429,
            500,
            502,
            503,
            504,
          ].contains(response.statusCode),
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const TextNetworkFailure('模型响应格式异常，费用待核对。');
      }
      return TextModelReply(decoded);
    } on TextNetworkFailure {
      rethrow;
    } on TimeoutException {
      throw const TextNetworkFailure('模型请求超时，可能已计费，预留未释放。', recoverable: true);
    } on HandshakeException {
      throw const TextNetworkFailure('安全连接失败，原文与费用预留保留。', recoverable: true);
    } on SocketException {
      throw const TextNetworkFailure('网络中断，可能已计费，预留未释放。', recoverable: true);
    } catch (_) {
      throw const TextNetworkFailure('模型响应未能确认，费用预留保留。');
    } finally {
      client.close(force: true);
    }
  }
}
