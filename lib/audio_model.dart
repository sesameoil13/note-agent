part of 'connection.dart';

/// Bailian's transcription model (ADR 0003), called through the same
/// OpenAI-compatible chat endpoint with the audio inline, digit rewriting off.
const transcriptionModelId = 'qwen3-asr-flash';

class AudioModelReply {
  const AudioModelReply(this.text);
  final String text;
}

extension WorkspaceAudioNetwork on WorkspaceConnection {
  /// Transcribes one part straight to Bailian with this device's key;
  /// nothing reaches the Worker (ADR 0004). No retries are implicit.
  Future<AudioModelReply> sendAudio({
    required List<int> bytes,
    required String mime,
  }) async {
    await _ensureLoaded();
    final key = _aiKey;
    if (key == null) {
      throw const ConnectionFailure('请先在 App 连接阿里云百炼。', code: 'credentials');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .postUrl(_textApiBase.resolve('chat/completions'))
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'model': transcriptionModelId,
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'input_audio',
                  'input_audio': {
                    'data': 'data:$mime;base64,${base64Encode(bytes)}',
                  },
                },
              ],
            },
          ],
          // Keep spoken numbers as said; "8:30a.m." does not suit a note.
          'asr_options': {'language': 'zh', 'enable_itn': false},
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 120),
      );
      final body = <int>[];
      await for (final chunk in response.timeout(
        const Duration(seconds: 120),
      )) {
        body.addAll(chunk);
        if (body.length > 1048576) {
          throw const ConnectionFailure('转写响应过大，原音保留。');
        }
      }
      if (response.statusCode != 200) {
        throw TextNetworkFailure(
          switch (response.statusCode) {
            401 || 403 => 'Key 无效或无转写权限，请在 App 重新连接。',
            402 => '阿里云账户余额不足，请充值后重试。',
            413 => '转写服务拒绝此文件大小，原音保留。',
            _ => '转写服务未返回完整结果，原音保留。',
          },
          code: switch (response.statusCode) {
            401 || 403 => 'credentials',
            402 => 'balance',
            _ => null,
          },
        );
      }
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map) {
        throw const ConnectionFailure('转写为空或格式异常，原音保留。');
      }
      final choices = decoded['choices'];
      final choice = choices is List && choices.length == 1
          ? choices.first
          : null;
      final message = choice is Map ? choice['message'] : null;
      final content = message is Map ? message['content'] : null;
      final text = content is String
          ? content
          : content is List
          ? content.map((c) => c is Map ? '${c['text'] ?? ''}' : '').join()
          : null;
      if (text == null || text.trim().isEmpty || text.contains('\u0000')) {
        throw const ConnectionFailure('转写为空或格式异常，原音保留。');
      }
      return AudioModelReply(text);
    } on TextNetworkFailure {
      rethrow;
    } on ConnectionFailure catch (e) {
      throw TextNetworkFailure(e.message);
    } catch (_) {
      throw const TextNetworkFailure('转写请求中断，原音保留。', recoverable: true);
    } finally {
      client.close(force: true);
    }
  }
}
