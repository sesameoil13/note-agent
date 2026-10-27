part of 'connection.dart';

/// Bailian's transcription model (ADR 0003), called through the same
/// OpenAI-compatible chat endpoint with the audio inline, digit rewriting off.
const transcriptionModelId = 'qwen3-asr-flash';

class AudioModelReply {
  const AudioModelReply(this.text, this.responseId, this.seconds);
  final String text;
  final String? responseId;

  /// Billed seconds as Bailian reports them; null when missing.
  final int? seconds;

  /// The receipt the Worker settles from, or null so the hold stays.
  Map<String, dynamic>? get settleBody => responseId == null || seconds == null
      ? null
      : {
          'responseId': responseId,
          'usage': {'seconds': seconds},
        };
}

extension WorkspaceAudioNetwork on WorkspaceConnection {
  /// One admitted part. No retries or remote file hosting are implicit.
  Future<AudioModelReply> sendReservedAudio(
    String attemptId, {
    required List<int> bytes,
    required String mime,
  }) async {
    await _ensureLoaded();
    final key = _aiKey;
    if (key == null) throw const ConnectionFailure('请先在 App 连接阿里云百炼。');
    await requestSharedBudget('/v1/budget/attempt/$attemptId/send', body: {});
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    String? responseId;
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
          throw const ConnectionFailure('转写响应过大，原音与费用预留保留。');
        }
      }
      if (response.statusCode != 200) {
        throw TextNetworkFailure(
          switch (response.statusCode) {
            401 || 403 => 'Key 无效或无转写权限，请在 App 重新连接。',
            402 => '阿里云账户余额不足，请在控制台核对。',
            413 => '转写服务拒绝此文件大小，原音保留。',
            _ => '转写服务未返回完整结果，可能已计费；请核对费用。',
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
        throw const ConnectionFailure('转写为空或格式异常，原音保留，费用待核对。');
      }
      final id = decoded['id'];
      if (id is String && RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(id)) {
        responseId = id;
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
        throw const ConnectionFailure('转写为空或格式异常，原音保留，费用待核对。');
      }
      final usage = decoded['usage'];
      final seconds = usage is Map ? usage['seconds'] : null;
      return AudioModelReply(
        text,
        responseId,
        seconds is int && seconds >= 0 && seconds <= 3600 ? seconds : null,
      );
    } on TextNetworkFailure {
      rethrow;
    } on ConnectionFailure catch (e) {
      throw TextNetworkFailure(e.message, generationId: responseId);
    } catch (_) {
      throw TextNetworkFailure(
        '转写请求中断，可能已计费；原音与预留保留，不自动重传。',
        generationId: responseId,
      );
    } finally {
      client.close(force: true);
    }
  }
}
